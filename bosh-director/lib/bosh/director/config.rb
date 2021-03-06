require 'fileutils'
require 'logging'

module Bosh::Director

  # We are in the slow painful process of extracting all of this class-level
  # behavior into instance behavior, much of it on the App class. When this
  # process is complete, the Config will be responsible only for maintaining
  # configuration information - not holding the state of the world.

  class Config
    class << self
      include DnsHelper

      CONFIG_OPTIONS = [
        :base_dir,
        :cloud_options,
        :db,
        :dns,
        :dns_db,
        :dns_domain_name,
        :event_log,
        :logger,
        :max_tasks,
        :max_threads,
        :name,
        :process_uuid,
        :result,
        :revision,
        :task_checkpoint_interval,
        :uuid,
        :current_job,
        :encryption,
        :fix_stateful_nodes,
        :enable_snapshots,
        :max_vm_create_tries,
        :nats_uri,
      ]

      CONFIG_OPTIONS.each do |option|
        attr_accessor option
      end

      attr_reader :db_config, :redis_logger_level

      def clear
        CONFIG_OPTIONS.each do |option|
          self.instance_variable_set("@#{option}".to_sym, nil)
        end

        Thread.list.each do |thr|
          thr[:bosh] = nil
        end

        @blobstore = nil

        @compiled_package_cache = nil
        @compiled_package_blobstore = nil
        @compiled_package_cache_options = nil

        @nats = nil
        @nats_rpc = nil
        @cloud = nil
      end

      def configure(config)
        @max_vm_create_tries = Integer(config.fetch('max_vm_create_tries', 5))

        @base_dir = config['dir']
        FileUtils.mkdir_p(@base_dir)

        # checkpoint task progress every 30 secs
        @task_checkpoint_interval = 30

        logging_config = config.fetch('logging', {})
        if logging_config.has_key?('file')
          @log_file_path = logging_config.fetch('file')
          shared_appender = Logging.appenders.file(
            'DirectorLogFile',
            filename: @log_file_path,
            layout: ThreadFormatter.layout
          )
        else
          shared_appender = Logging.appenders.io(
            'DirectorStdOut',
            STDOUT,
            layout: ThreadFormatter.layout
          )
        end

        @logger = Logging::Logger.new('Director')
        @logger.add_appenders(shared_appender)
        @logger.level = Logging.levelify(logging_config.fetch('level', 'debug'))

        # use a separate logger with the same appender to avoid multiple file writers
        redis_logger = Logging::Logger.new('DirectorRedis')
        redis_logger.add_appenders(shared_appender)
        logging_config = config.fetch('redis', {}).fetch('logging', {})
        @redis_logger_level = Logging.levelify(logging_config.fetch('level', 'info'))
        redis_logger.level = @redis_logger_level

        # Event logger supposed to be overridden per task,
        # the default one does nothing
        @event_log = EventLog::Log.new

        # by default keep only last 500 tasks in disk
        @max_tasks = config.fetch('max_tasks', 500).to_i

        @max_threads = config.fetch('max_threads', 32).to_i

        self.redis_options = {
          :host     => config['redis']['host'],
          :port     => config['redis']['port'],
          :password => config['redis']['password'],
          :logger   => redis_logger
        }

        @revision = get_revision

        @logger.info("Starting BOSH Director: #{VERSION} (#{@revision})")

        @process_uuid = SecureRandom.uuid
        @nats_uri = config['mbus']

        @cloud_options = config['cloud']
        @compiled_package_cache_options = config['compiled_package_cache']
        @name = config['name'] || ''

        @compiled_package_cache = nil

        @db_config = config['db']
        @db = configure_db(config['db'])
        @dns = config['dns']
        @dns_domain_name = 'bosh'
        if @dns
          @dns_db = configure_db(@dns['db']) if @dns['db']
          @dns_domain_name = canonical(@dns['domain_name']) if @dns['domain_name']
        end

        @uuid = override_uuid || Bosh::Director::Models::DirectorAttribute.find_or_create_uuid(@logger)
        @logger.info("Director UUID: #{@uuid}")

        @encryption = config['encryption']
        @fix_stateful_nodes = config.fetch('scan_and_fix', {})
          .fetch('auto_fix_stateful_nodes', false)
        @enable_snapshots = config.fetch('snapshots', {}).fetch('enabled', false)

        Bosh::Clouds::Config.configure(self)

        @lock = Monitor.new
      end

      def log_dir
        File.dirname(@log_file_path) if @log_file_path
      end

      def use_compiled_package_cache?
        !@compiled_package_cache_options.nil?
      end

      def get_revision
        Dir.chdir(File.expand_path('../../../../../..', __FILE__))
        revision_command = '(cat REVISION 2> /dev/null || ' +
            'git show-ref --head --hash=8 2> /dev/null || ' +
            'echo 00000000) | head -n1'
        `#{revision_command}`.strip
      end

      def configure_db(db_config)
        patch_sqlite if db_config['adapter'] == 'sqlite'

        connection_options = db_config.delete('connection_options') {{}}
        db_config.delete_if { |_, v| v.to_s.empty? }
        db_config = db_config.merge(connection_options)

        db = Sequel.connect(db_config)
        if logger
          db.logger = logger
          db.sql_log_level = :debug
        end

        db
      end

      def compiled_package_cache_blobstore
        @lock.synchronize do
          if @compiled_package_cache_blobstore.nil? && use_compiled_package_cache?
            provider = @compiled_package_cache_options['provider']
            options = @compiled_package_cache_options['options']
            @compiled_package_cache_blobstore = Bosh::Blobstore::Client.safe_create(provider, options)
          end
        end
        @compiled_package_cache_blobstore
      end

      def compiled_package_cache_provider
        use_compiled_package_cache? ? @compiled_package_cache_options['provider'] : nil
      end

      def cloud_type
        if @cloud_options
          @cloud_options['plugin']
        end
      end

      def cloud
        @lock.synchronize do
          if @cloud.nil?
            @cloud = Bosh::Clouds::Provider.create(@cloud_options, @uuid)
          end
        end
        @cloud
      end

      def cpi_task_log
        Config.cloud_options.fetch('properties', {}).fetch('cpi_log')
      end

      def job_cancelled?
        @current_job.task_checkpoint if @current_job
      end

      alias_method :task_checkpoint, :job_cancelled?

      def redis_options
        @redis_options ||= {}
      end

      def redis_logger_level
        @redis_logger_level || Logger::INFO
      end

      def redis_options=(options)
        @redis_options = options
      end

      def cloud_options=(options)
        @lock.synchronize do
          @cloud_options = options
          @cloud = nil
        end
      end

      def nats_rpc
        # double-check locking to reduce synchronization
        if @nats_rpc.nil?
          @lock.synchronize do
            if @nats_rpc.nil?
              @nats_rpc = NatsRpc.new(@nats_uri)
            end
          end
        end
        @nats_rpc
      end

      def redis
        threaded[:redis] ||= Redis.new(redis_options)
      end

      def redis_logger=(logger)
        if redis?
          redis.client.logger = logger
        else
          redis_options[:logger] = logger
        end
      end

      def redis?
        !threaded[:redis].nil?
      end

      def dns_enabled?
        !@dns_db.nil?
      end

      def encryption?
        @encryption
      end

      def threaded
        Thread.current[:bosh] ||= {}
      end

      def patch_sqlite
        return if @patched_sqlite
        @patched_sqlite = true

        require 'sequel'
        require 'sequel/adapters/sqlite'

        Sequel::SQLite::Database.class_eval do
          def connect(server)
            opts = server_opts(server)
            opts[:database] = ':memory:' if blank_object?(opts[:database])
            db = ::SQLite3::Database.new(opts[:database])
            db.busy_handler do |retries|
              Bosh::Director::Config.logger.debug "SQLITE BUSY, retry ##{retries}"
              sleep(0.1)
              retries < 20
            end

            connection_pragmas.each { |s| log_yield(s) { db.execute_batch(s) } }

            class << db
              attr_reader :prepared_statements
            end
            db.instance_variable_set(:@prepared_statements, {})

            db
          end
        end
      end

      def override_uuid
        new_uuid = nil
        state_file = File.join(base_dir, 'state.json')

        if File.exists?(state_file)
          open(state_file, 'r+') do |file|

            # Lock before read to avoid director/worker race condition
            file.flock(File::LOCK_EX)
            state = Yajl::Parser.parse(file) || {}

            # Empty state file to prevent blocked processes from attempting to set UUID
            file.truncate(0)

            if state['uuid']
              Bosh::Director::Models::DirectorAttribute.update_or_create_uuid(state['uuid'], @logger)
              @logger.info("Using director UUID #{state['uuid']} from #{state_file}")
              new_uuid = state['uuid']
            end

            # Unlock after storing UUID
            file.flock(File::LOCK_UN)
          end

          FileUtils.rm_f(state_file)
        end

        new_uuid
      end
    end

    class << self
      def load_file(path)
        Config.new(Psych.load_file(path))
      end

      def load_hash(hash)
        Config.new(hash)
      end
    end

    attr_reader :hash

    private

    def initialize(hash)
      @hash = hash
    end
  end
end
