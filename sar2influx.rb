#!/usr/bin/env ruby

require 'net/https'
require 'open3'
require 'optparse'
require 'rubygems/requirement'
require 'tempfile'
require 'uri'

module PBug
# Tools for importing Puppet metrics into time series databases
#
# @todo HTTP output not fully plumbed in. Needs to be done in
#   batches of ~10,000 lines as there is a limit to how much
#   data InfluxDB will accept in a single POST. For now,
#   dump stdout to a file, `split -l10000` it, then use curl
#   to POST the resulting `x*` files with `--data-binary`.
module ImportSARMetrics
  VERSION = '0.1.0'.freeze
  REQUIRED_RUBY_VERSION = Gem::Requirement.new('>= 2.1')

  # Write data to the standard output
  class StandardOutput
   def write(data)
     $stdout.write(data)
   rescue Errno::EPIPE
     # Stdout is closed. This is normal when the output of this script is
     # piped to something else that exits early, like `head`.
   end

   def close
   end
  end

  # Write data to InfluxDB using HTTPS
  class InfluxDBOutput
    # TODO: Support HTTPS.
    def initialize(host_url)
      @url = URI.parse(host_url) unless host_url.is_a?(URI)
      @connection = nil

      open
    end

    def open
      return if @connection

      $stderr.puts('INFO: Connecting to InfluxDB server at %{hostname}:%{port}' %
                   {hostname: @url.hostname,
                    port: @url.port})

      http = Net::HTTP.new(@url.hostname, @url.port)
      http.keep_alive_timeout = 20
      http.start

      @connection = http
    end

    def write(data)
      request = Net::HTTP::Post.new(@url)
      request['Connection'] = 'keep-alive'
      response = @connection.request(request, data)
      # TODO: Raise an error if the request fails.
    end

    def close
      if @connection
	$stderr.puts('INFO: Closing connection to InfluxDB server at %{hostname}:%{port}' %
		     {hostname: @url.hostname,
		      port: @url.port})
	
	@connection.finish
      end
    ensure
      @connection = nil
    end
  end

  class CLI
    ARG_SPECS = [['--pattern PATTERN',
                  'Glob pattern of files to load.',
                  'Must be provided if no files are passed.'],
                 ['--db-host HOSTNAME|IP_ADDRESS',
                  'Hostname to submit converted data to.',
                  'Leave blank to print converted data to stdout.'],
                 ['--db-name NAME',
                  'Database name to submit converted data to.',
                  'Required if --db-host is used.']]

    def initialize(argv = [])
      @data_files = []
      @action = :parse_data
      @options = {}
      @output = StandardOutput.new

      store_option = lambda do |hash, key, val|
        hash[key] = val
      end

      @optparser = OptionParser.new do |parser|
        parser.banner = "Usage: sar2influxdb.rb [options] [sadd|sadd.gz] [...]"

        parser.on_tail('-h', '--help', 'Show help') do
          @action = :show_help
        end

        parser.on_tail('--debug', 'Enable backtraces from errors.') do
          @options[:debug] = true
        end

        parser.on_tail('--version', 'Show version') do
          @action = :show_version
        end
      end

      ARG_SPECS.each do |spec|
        # TODO: Yell if ARG_SPECS entry contains no --long-flag.
        long_flag = spec.find {|e| e.start_with?('--')}.split(' ').first
        option_name = long_flag.sub(/\A-+(?:\[no-\])?/, '').gsub('-', '_').to_sym

        @optparser.on(store_option.curry[@options][option_name], *spec)
      end

      # Now that sub-parsers have been defined for each option, use them
      # to parse PT_ environment variables that are set if this script is
      # invoked as a task.
      @optparser.top.list.each do |option|
        option_name = option.switch_name.gsub('-', '_')
        task_var = "PT_#{option_name}"

        next unless ENV.has_key?(task_var)

        @options[option_name.to_sym] = option.parse(ENV[task_var], []).last
      end

      args = argv.dup
      @optparser.parse!(args)

      # parse! consumes all --flags and their arguments leaving
      # file names behind.
      @data_files += args
    end

    # Parse files and print results to STDERR
    #
    # @return [Integer] An integer representing process exit code that can be
    #   set by the caller.
    def run
      case @action
      when :show_help
        $stdout.puts(@optparser.help)
        return 0
      when :show_version
        $stdout.puts(VERSION)
        return 0
      end

      if not REQUIRED_RUBY_VERSION.satisfied_by?(Gem::Version.new(RUBY_VERSION))
        $stderr.puts("import_metrics.rb requires Ruby #{REQUIRED_RUBY_VERSION}")
        return 1
      end

      @data_files += Dir.glob(@options[:pattern]) if @options[:pattern]

      if @data_files.empty?
        $stderr.puts('ERROR: No data files to parse.')
        $stderr.puts(@optparser.help)
        return 1
      end

      find_sar_commands!

      if @options.key?(:db_host) && !@options.key?(:db_name)
        raise ArgumentError, "--db-name must be passsed along with --db-host"
      end

      if @options[:db_host]
        @output = InfluxDBOutput.new("http://#{@options[:db_host]}:8086/write?db=#{@options[:db_name]}&precision=s")
      end

      @data_files.each do |filename|
        $stderr.puts("INFO: Processing #{filename}")

        data = parse_sar_archive(filename)

        # Split into 10,000 line chunks to prevent InfluxDB from
        # rejecting large payloads.
        data.each_slice(10_000) do |chunk|
          @output.write(format_sar_data(chunk).join("\n"))
        end
      end

      return 0
    rescue => e
      message = if @options[:debug]
                  ["ERROR #{e.class}: #{e.message}",
                   e.backtrace].join("\n\t")
                else
                  "ERROR #{e.class}: #{e.message}"
                end

      $stderr.puts(message)
      return 1
    ensure
      @output.close
    end

    # Find SAR commands
    #
    # This method locates the `sadf` executable, which is
    # used to extract and format data stored in SAR archives.
    # This tool is commonly provided by the `sysstat` package
    # and version 11.1.1 or newer is required.
    #
    # @return void
    # @raise [RuntimeError] If sadf is not found or is not an
    #   acceptable version.
    def find_sar_commands!
      stdout, stderr, have_sadf = Open3.capture3('/bin/sh', '-c', 'command -v sadf')

      if have_sadf.success?
        @sadf = stdout.chomp!
      else
        raise RuntimeError, [stdout,
                             stderr,
                             "\nsar2influxdb requires sadf from the Linux sysstat package to be on the $PATH."].join("\n")
      end

      
      stdout, stderr, got_sadf_version  = Open3.capture3(@sadf, '-V')

      unless got_sadf_version.success? && (sadf_version = stdout.match(/sysstat version (\d+\.\d+\.\d+)/))
        raise RuntimeError, "Could not determine sysstat version. '%{cmd} -V' returned:\n%{stdout}\n%{stderr}" %
                            {cmd: @sadf,
                             stdout: stdout,
                             stderr: stderr}
      end
      
      sadf_version = sadf_version.captures.first

      unless Gem::Requirement.new('>= 11.1.1').satisfied_by?(Gem::Version.new(sadf_version))
        raise RuntimeError, "sar2influxdb requires sysstat 11.1.1 or newer. '%{cmd} -V' reported the following version: %{version}" %
                            {cmd: @sadf,
                             version: sadf_version}
      end

      $stderr.puts('INFO: using %{cmd} version: %{version}' % {cmd: @sadf, version: sadf_version})
    end

    # Parse SAR data
    #
    # This function executes `sadf` to extract all data from a SAR archive
    # produced by `sa1`. Patterned after the Telegraf sysstat plugin, but able
    # to process historical archives instead of internally running `sadc` and
    # parsing its output.
    #
    # @note You may have to run this script in an environment that has the
    #   same version of sysstat as the environment that produced the archive.
    #   Docker containers are a great way to do this.
    #
    # @todo Handle gzipped archives.
    #
    # @see https://github.com/influxdata/telegraf/tree/master/plugins/inputs/sysstat
    #
    # @param filename [String] The path to a sa1 archive.
    #
    # @return [Enumerator<Hash>] An enumerator that produces a hash of data
    #   for each entry in the archive.
    def parse_sar_archive(filename)
      tempfile = Tempfile.create('sar2timeseriesdb')
      tempfile.close

      # Convert SAR data produced by older versions of sysstat.
      pid = Process.spawn(@sadf, '-c', filename, {out: [tempfile.path, 'w'], err: :close, in: :close})
      # FIXME: Check exit status and print stderr if something fails.
      Process.waitpid2(pid)

      stdin, stdout, wait_thr = Open3.popen2(@sadf, '-Up', tempfile.path, '--', '-A')
      # We have nothing to say to `sadf`.
      stdin.close

      iterator = stdout.each_line

      Enumerator.new do |yielder|
        iterator.each do |line|
          begin
	    hostname, interval, timestamp, name, field, value = line.split(/\s+/)
            next if field.nil? # one-off events, like restarts

	    # Sanitize characters that InfluxDB considers special.
	    field.gsub!('%%', 'pct_')
	    field.gsub!('%', 'pct_')
	    field.gsub!('/', '_per_')

	    yielder.yield({hostname: hostname,
			   interval: interval,
			   timestamp: timestamp,
			   name: name,
			   field: field,
			   value: value})
          rescue => e
            $stderr.puts("ERROR: parsing %{file} failed: %{line}" %
                         {file: filename,
                          line: line})
            raise e
          end
        end

        # `sadf` has returned all of its data. Close the pipe out.
        stdout.close
        File.unlink(tempfile)
      end
    end

    # Convert SAR data to InfluxDB line protocol
    def format_sar_data(data)
      data.map do |entry|
        entry[:tags] = case entry[:name]
                       when '-'
                         'server=%{hostname}' % entry
                       else
                         'server=%{hostname},name=%{name}' % entry
                       end

        'sar,%{tags} %{field}=%{value} %{timestamp}' % entry
      end
    end
  end
end
end


# Entrypoint for when this file is executed directly.
if File.expand_path(__FILE__) == File.expand_path($PROGRAM_NAME)
  exit_code = PBug::ImportSARMetrics::CLI.new(ARGV).run
  exit exit_code
end