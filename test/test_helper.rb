require 'bundler/setup'

# ENV variables supported :
# - AR_POOL_SIZE=42 for testing out with higher pools
# - AR_POOL_CHECKOUT_TIMEOUT=2 for changing the pool connection acquire timeout
# - AR_POOL_PREFILL=10 how many connections to "prefill" the pool with on start
# - AR_POOL_SHARED=true/false or size/percentage (0.0-1.0) connection sharing
# - AR_PREPARED_STATEMENTS=true/false

connect_timeout = 5
checkout_timeout = 2.5 # default is to wait 5 seconds when all connections used
pool_size = 10
#pool_prefill = 10 # (or simply true/false) how many connections to initialize
shared_pool = 0.75 # shareable pool true/false or size (integer or percentage)
ENV['DB_POOL_SHARED'] ||= 0.5.to_s

# NOTE: max concurrent threads handled before explicit locking with shared :
#   pool_size - ( pool_size * shared_pool ) * MAX_THREAD_SHARING (5)
#   e.g. 40 - ( 40 * 0.75 ) * 5 = 160

require 'active_record'

require 'logger'
ActiveRecord::Base.logger = Logger.new(STDOUT)

#shared_pool = ENV['AR_POOL_SHARED'] ? # with AR_POOL_SHARED=true use default
#  ( ENV['AR_POOL_SHARED'] == 'true' ? shared_pool : ENV['AR_POOL_SHARED'] ) :
#    shared_pool
#if shared_pool && shared_pool.to_s != 'false'
#  shared_pool = Float(shared_pool) rescue nil # to number if number
#  require 'active_record/connection_adapters/shareable_connection_pool'
#  # ActiveRecord::Base.default_connection_handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new
#  pool_class = ActiveRecord::ConnectionAdapters::ShareableConnectionPool
#  ActiveRecord::ConnectionAdapters::ConnectionHandler.connection_pool_class = pool_class
#end

config = { :'adapter' => ENV['AR_ADAPTER'] || 'sqlite3' }
config[:'username'] = ENV['AR_USERNAME'] if ENV['AR_USERNAME']
config[:'password'] = ENV['AR_PASSWORD'] if ENV['AR_PASSWORD']
if url = ENV['AR_URL'] || ENV['JDBC_URL']
  config[:'url'] = url
else
  config[:'database'] = ENV['AR_DATABASE'] || 'ar_basin'
end

config[:'pool'] = ENV['AR_POOL_SIZE'] ? ENV['AR_POOL_SIZE'].to_i : pool_size
config[:'shared_pool'] = ENV['AR_POOL_SHARED'] || shared_pool
config[:'connect_timeout'] = connect_timeout
prepared_statements = ENV['AR_PREPARED_STATEMENTS'] # || true
config[:'prepared_statements'] = prepared_statements if prepared_statements
#jdbc_properties = { 'logUnclosedConnections' => true, 'loginTimeout' => 5 }
#config['properties'] = jdbc_properties

checkout_timeout = ENV['AR_POOL_CHECKOUT_TIMEOUT'] || checkout_timeout
config[:'checkout_timeout'] = checkout_timeout.to_f if checkout_timeout

AR_CONFIG = config

unless ENV['Rake'] == 'true'
  gem 'test-unit'
  require 'test/unit'

  ActiveRecord::Base.logger.debug "database configuration: #{config.inspect}"
end

#pool = ActiveRecord::Base.connection_pool
#pool_prefill = ENV['AR_POOL_PREFILL']
#pool_prefill = pool.size if pool_prefill.to_s == 'true'
#pool_prefill = 0 if pool_prefill.to_s == 'false'
#
#if ( pool_prefill = ( pool_prefill || 10 ).to_i ) > 0
#  pool_prefill = pool.size if pool_prefill > pool.size
#
#  conns = []; start = Time.now
#  ActiveRecord::Base.logger.info "pre-filling pool with #{pool_prefill}/#{pool.size} connections"
#  begin
#    pool_prefill.times { conns << pool.checkout }
#  ensure
#    conns.each { |conn| pool.checkin(conn) }
#  end
#
#  # NOTE: for 50 connections ~ 2 seconds but in real time this might get
#  # slower due synchronization - more threads using the pool = more time
#  ActiveRecord::Base.logger.debug "pre-filling connection pool took #{Time.now - start}"
#end
#
#if ENV['AR_POOL_BENCHMARK'] && ENV['AR_POOL_BENCHMARK'].to_s != 'false'
#  require 'active_record/connection_adapters/pool_benchmark'
#  pool.extend ActiveRecord::ConnectionAdapters::PoolBenchmark
#end

require 'active_record/basin'

$LOAD_PATH << File.expand_path(File.dirname(__FILE__))

module ActiveRecord
  module ConnectionAdapters
    ConnectionPool.class_eval do
      attr_reader :available # the custom Queue
      attr_reader :reserved_connections # Thread-Cache
      # attr_reader :connections # created connections
    end
    autoload :ConnectionPoolTestMethods, 'active_record/connection_pool_test_methods'
  end
end

module ActiveRecord
  module Basin

    module TestHelper

      def with_connection(config)
        ActiveRecord::Base.establish_connection config
        yield ActiveRecord::Base.connection
      ensure
        ActiveRecord::Base.connection.disconnect!
      end

      def with_connection_removed
        connection = ActiveRecord::Base.remove_connection
        begin
          yield
        ensure
          ActiveRecord::Base.establish_connection connection
        end
      end

#      def with_connection_removed
#        configurations = ActiveRecord::Base.configurations
#        connection_config = current_connection_config
#        # ActiveRecord::Base.connection.disconnect!
#        ActiveRecord::Base.remove_connection
#        begin
#          yield connection_config.dup
#        ensure
#          # ActiveRecord::Base.connection.disconnect!
#          ActiveRecord::Base.remove_connection
#          ActiveRecord::Base.configurations = configurations
#          ActiveRecord::Base.establish_connection connection_config
#        end
#      end

      module_function

      def current_connection_config
        if ActiveRecord::Base.respond_to?(:connection_config)
          ActiveRecord::Base.connection_config
        else
          ActiveRecord::Base.connection_pool.spec.config
        end
      end

      def silence_deprecations(&block)
        ActiveSupport::Deprecation.silence(&block)
      end

#      def disable_logger(connection, &block)
#        raise "need a block" unless block_given?
#        return disable_connection_logger(connection, &block) if connection
#        logger = ActiveRecord::Base.logger
#        begin
#          ActiveRecord::Base.logger = nil
#          yield
#        ensure
#          ActiveRecord::Base.logger = logger
#        end
#      end
#
#      def disable_connection_logger(connection)
#        logger = connection.send(:instance_variable_get, :@logger)
#        begin
#          connection.send(:instance_variable_set, :@logger, nil)
#          yield
#        ensure
#          connection.send(:instance_variable_set, :@logger, logger)
#        end
#      end

    end

    module JndiTestHelper

      def setup_jdbc_context
        load 'test/jars/tomcat-juli.jar'
        load 'test/jars/tomcat-catalina.jar'

        java.lang.System.set_property(
            javax.naming.Context::INITIAL_CONTEXT_FACTORY,
            'org.apache.naming.java.javaURLContextFactory'
        )
        java.lang.System.set_property(
            javax.naming.Context::URL_PKG_PREFIXES,
            'org.apache.naming'
        )

        init_context = javax.naming.InitialContext.new
        begin
          init_context.create_subcontext 'jdbc'
        rescue javax.naming.NameAlreadyBoundException
        end
      end

      def init_tomcat_jdbc_data_source(ar_jdbc_config = AR_CONFIG)
        load 'test/jars/tomcat-jdbc.jar'

        unless driver = ar_jdbc_config[:driver]
          jdbc_driver_module.load_driver
          driver = jdbc_driver_module.driver_name
        end

        data_source = org.apache.tomcat.jdbc.pool.DataSource.new
        data_source.setDriverClassName driver
        data_source.setUrl ar_jdbc_config[:url]
        data_source.setUsername ar_jdbc_config[:username] if ar_jdbc_config[:username]
        data_source.setPassword ar_jdbc_config[:password] if ar_jdbc_config[:password]

        data_source
      end

      def bind_data_source(data_source, jndi_name = jndi_config[:jndi])
        load_driver
        javax.naming.InitialContext.new.bind jndi_name, data_source
      end

      def load_driver
        jdbc_driver_module.load_driver
      end

      def jdbc_driver_module
        driver = jndi_config[:adapter]
        driver = 'postgres' if driver == 'postgresql'
        require "jdbc/#{driver}"
        ::Jdbc.const_get ::Jdbc.constants.first
      end

      def jndi_config
        @jndi_config ||= { :adapter => AR_CONFIG[:adapter], :jndi => jndi_name }
      end

      def jndi_name; 'jdbc/TestDB' end

    end
  end
end