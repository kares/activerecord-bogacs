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
require 'arjdbc' if defined? JRUBY_VERSION

require 'logger'
ActiveRecord::Base.logger = Logger.new(STDOUT)

puts "testing with ActiveRecord #{ActiveRecord::VERSION::STRING}"

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

config = { :adapter => ENV['AR_ADAPTER'] || 'sqlite3' }
config[:username] = ENV['AR_USERNAME'] if ENV['AR_USERNAME']
config[:password] = ENV['AR_PASSWORD'] if ENV['AR_PASSWORD']
if url = ENV['AR_URL'] || ENV['JDBC_URL']
  config[:'url'] = url
else
  config[:'host'] = ENV['AR_HOST'] || 'localhost'
  config[:'database'] = ENV['AR_DATABASE'] || 'ar_bogacs'
end

config[:'pool'] = ENV['AR_POOL_SIZE'] ? ENV['AR_POOL_SIZE'].to_i : pool_size
config[:'shared_pool'] = ENV['AR_POOL_SHARED'] || shared_pool
config[:'connect_timeout'] = connect_timeout
prepared_statements = ENV['AR_PREPARED_STATEMENTS'] # || true
config[:'prepared_statements'] = prepared_statements if prepared_statements
#jdbc_properties = { 'logUnclosedConnections' => true, 'loginTimeout' => 5 }
#config[:'properties'] = jdbc_properties
config[:'properties'] ||= {}
config[:'properties']['useSSL'] ||= 'false' if config[:adapter].starts_with?('mysql')

checkout_timeout = ENV['AR_POOL_CHECKOUT_TIMEOUT'] || checkout_timeout
config[:'checkout_timeout'] = checkout_timeout.to_f if checkout_timeout

AR_CONFIG = config

pool_prefill = ENV['AR_POOL_PREFILL']
pool_prefill = config[:'pool'] if pool_prefill.to_s == 'true'
pool_prefill = 0 if pool_prefill.to_s == 'false'
config[:'pool_prefill'] = pool_prefill.to_i if pool_prefill # NOTE: not yet used

unless ENV['Rake'] == 'true'
  gem 'test-unit'
  require 'test/unit'

  ActiveRecord::Base.logger.debug "database configuration: #{config.inspect}"
end

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

require 'active_record/bogacs'

$LOAD_PATH << File.expand_path(File.dirname(__FILE__))

module ActiveRecord
  module ConnectionAdapters
    ConnectionPool.class_eval do
      attr_reader :size # only since 4.x
      attr_reader :available # the custom Queue
      attr_reader :reserved_connections # Thread-Cache
      # attr_reader :connections # created connections
    end
    autoload :ConnectionPoolTestMethods, 'active_record/connection_pool_test_methods'
  end
end

module ActiveRecord
  module Bogacs

    require 'concurrent/atomic/atomic_reference'
    Atomic = Concurrent::AtomicReference

    module TestHelper

      def _test_name
        @method_name # @__name__ on mini-test
      end
      private :_test_name

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

      protected

      @@sample_query = ENV['SAMPLE_QUERY']
      @@test_query = ENV['TEST_QUERY'] || @@sample_query

      def sample_query
        @@sample_query ||= begin
          case current_connection_config[:adapter]
          when /mysql/ then 'SHOW VARIABLES LIKE "%version%"'
          when /postgresql/ then 'SELECT version()'
          else 'SELECT 42'
          end
        end
      end

      def test_query
        @@test_query ||= begin
          case current_connection_config[:adapter]
          when /mysql/ then 'SELECT DATABASE() FROM DUAL'
          when /postgresql/ then 'SELECT current_database()'
          else sample_query
          end
        end
      end

    end

    module JndiTestHelper

      @@setup_jdbc_context = nil

      def setup_jdbc_context!
        load_jar 'test/jars/tomcat-juli.jar'
        load_jar 'test/jars/tomcat-catalina.jar'

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

      def setup_jdbc_context
        @@setup_jdbc_context || setup_jdbc_context!
        @@setup_jdbc_context = true
      end

      def build_tomcat_jdbc_data_source(ar_jdbc_config = AR_CONFIG)
        load_jar 'test/jars/tomcat-jdbc.jar'

        data_source = org.apache.tomcat.jdbc.pool.DataSource.new
        configure_dbcp_data_source(data_source, ar_jdbc_config)

        data_source.setJmxEnabled false

        data_source
      end

      def build_tomcat_dbcp_data_source(ar_jdbc_config = AR_CONFIG)
        load_jar 'test/jars/tomcat-dbcp.jar'

        data_source = org.apache.tomcat.dbcp.dbcp.BasicDataSource.new
        configure_dbcp_data_source(data_source, ar_jdbc_config)

        data_source.setAccessToUnderlyingConnectionAllowed true

        data_source
      end

      def build_commons_dbcp_data_source(ar_jdbc_config = AR_CONFIG)
        load_jar Dir.glob('test/jars/{commons-dbcp}*.jar').first

        data_source = org.apache.tomcat.dbcp.dbcp.BasicDataSource.new
        configure_dbcp_data_source(data_source, ar_jdbc_config)

        data_source.setAccessToUnderlyingConnectionAllowed true

        data_source
      end

      def configure_dbcp_data_source(data_source, ar_jdbc_config)
        unless driver = ar_jdbc_config[:driver]
          jdbc_driver_module.load_driver
          driver = jdbc_driver_module.driver_name
        end

        data_source.setDriverClassName driver
        data_source.setUrl ar_jdbc_config[:url]
        data_source.setUsername ar_jdbc_config[:username] if ar_jdbc_config[:username]
        data_source.setPassword ar_jdbc_config[:password] if ar_jdbc_config[:password]
        if properties = ar_jdbc_config[:properties]
          if data_source.respond_to?(:setDbProperties) # TC-JDBC
            db_properties = java.util.Properties.new
            properties.each { |name, value| db_properties.put(name, value.to_s) }
            data_source.setDbProperties db_properties
          else # Tomcat-DBCP / Commons DBCP2
            properties.each do |name, val|
              data_source.addConnectionProperty name, val
            end
          end
        end
        # JDBC pool tunings (some mapped from AR configuration) :
        if ar_jdbc_config[:pool] # default is 100
          data_source.setMaxActive ar_jdbc_config[:pool]
          if prefill = ar_jdbc_config[:pool_prefill]
            data_source.setInitialSize prefill
          end
          if data_source.max_active < data_source.max_idle
            data_source.setMaxIdle data_source.max_active
          end
        end
        max_wait = ar_jdbc_config[:checkout_timeout] || 5
        data_source.setMaxWait max_wait * 1000 # default is 30s

        data_source.setTestWhileIdle false # default

        #data_source.setRemoveAbandoned false
        #data_source.setLogAbandoned true
      end
      private :configure_dbcp_data_source

      def build_c3p0_data_source(ar_jdbc_config = AR_CONFIG)
        Dir.glob('test/jars/{c3p0,mchange-commons}*.jar').each { |jar| load_jar jar }

        data_source = com.mchange.v2.c3p0.ComboPooledDataSource.new
        configure_c3p0_data_source(data_source, ar_jdbc_config)

        data_source
      end

      def configure_c3p0_data_source(data_source, ar_jdbc_config)
        unless driver = ar_jdbc_config[:driver]
          jdbc_driver_module.load_driver
          driver = jdbc_driver_module.driver_name
        end

        data_source.setDriverClass driver
        data_source.setJdbcUrl ar_jdbc_config[:url]
        if user = ar_jdbc_config[:username]
          # data_source.setUser user # WTF C3P0
          data_source.setOverrideDefaultUser user
        end
        data_source.setPassword ar_jdbc_config[:password] if ar_jdbc_config[:password]

        if ar_jdbc_config[:properties]
          properties = java.util.Properties.new
          ar_jdbc_config[:properties].each { |key, val| properties.put key.to_s, val.to_s }
          data_source.setProperties properties
        end
        # JDBC pool tunings (some mapped from AR configuration) :
        if ar_jdbc_config[:pool] # default is 100
          data_source.setMaxPoolSize ar_jdbc_config[:pool].to_i
          if prefill = ar_jdbc_config[:pool_prefill]
            data_source.setInitialPoolSize prefill.to_i
          end
        end
        checkout_timeout = ar_jdbc_config[:checkout_timeout] || 5
        data_source.setCheckoutTimeout checkout_timeout * 1000

        data_source.setAcquireIncrement 1 # default 3
        data_source.setAcquireRetryAttempts 3 # default 30
        data_source.setAcquireRetryDelay 1000 # default 1000
        data_source.setNumHelperThreads 2 # default 3
      end
      private :configure_c3p0_data_source


      def build_hikari_data_source(ar_jdbc_config = AR_CONFIG)
        unless hikari_jar = Dir.glob('test/jars/HikariCP*.jar').sort.last
          raise 'HikariCP jar not found in test/jars directory'
        end
        if ( version = File.basename(hikari_jar, '.jar').match(/\-([\w\.\-]$)/) ) && version[1] < '2.3.9'
          Dir.glob('test/jars/{javassist,slf4j}*.jar').each { |jar| load_jar jar }
        else
          Dir.glob('test/jars/{slf4j}*.jar').each { |jar| load_jar jar }
        end
        load_jar hikari_jar

        configure_hikari_data_source(ar_jdbc_config)
      end

      def configure_hikari_data_source(ar_jdbc_config)
        hikari_config = com.zaxxer.hikari.HikariConfig.new

        unless driver = ar_jdbc_config[:driver]
          jdbc_driver_module.load_driver
          driver = jdbc_driver_module.driver_name
        end

        case driver
        when /mysql/i
          puts "DRIVER: #{driver.inspect}"
          data_source_class_name = if driver == 'com.mysql.cj.jdbc.Driver'
            'com.mysql.cj.jdbc.MysqlDataSource' # driver 8.0
          else
            'com.mysql.jdbc.jdbc2.optional.MysqlDataSource' # old 5.x
          end
          hikari_config.setDataSourceClassName data_source_class_name
          hikari_config.addDataSourceProperty 'serverName', ar_jdbc_config[:host] || 'localhost'
          hikari_config.addDataSourceProperty 'databaseName', ar_jdbc_config[:database]
          hikari_config.addDataSourceProperty 'port', ar_jdbc_config[:port] if ar_jdbc_config[:port]
          if true
            hikari_config.addDataSourceProperty 'user', ar_jdbc_config[:username] || 'root'
          end
          if ar_jdbc_config[:password]
            hikari_config.addDataSourceProperty 'password', ar_jdbc_config[:password]
          end
          ( ar_jdbc_config[:properties] || {} ).each do |name, val|
            hikari_config.addDataSourceProperty name.to_s, val.to_s
          end
        when /postgres/i
          hikari_config.setDataSourceClassName 'org.postgresql.ds.PGSimpleDataSource'
          hikari_config.addDataSourceProperty 'serverName', ar_jdbc_config[:host] || 'localhost'
          hikari_config.addDataSourceProperty 'databaseName', ar_jdbc_config[:database]
          hikari_config.addDataSourceProperty 'portNumber', ar_jdbc_config[:port] if ar_jdbc_config[:port]
          if ar_jdbc_config[:username]
            hikari_config.addDataSourceProperty 'user', ar_jdbc_config[:username]
          end
          if ar_jdbc_config[:password]
            hikari_config.addDataSourceProperty 'password', ar_jdbc_config[:password]
          end
          ( ar_jdbc_config[:properties] || {} ).each do |name, val|
            hikari_config.addDataSourceProperty name.to_s, val.to_s
          end
        else
          hikari_config.setDriverClassName driver
          hikari_config.setJdbcUrl ar_jdbc_config[:url]
          hikari_config.setUsername ar_jdbc_config[:username] if ar_jdbc_config[:username]
          hikari_config.setPassword ar_jdbc_config[:password] if ar_jdbc_config[:password]
        end
        hikari_config.setJdbcUrl ar_jdbc_config[:url] if ar_jdbc_config[:url]

        # TODO: we shall handle raw properties ?!
        #if ar_jdbc_config[:properties]
        #  properties = java.util.Properties.new
        #  properties.putAll ar_jdbc_config[:properties]
        #  hikari_config.setProperties properties
        #end

        # JDBC pool tunings (some mapped from AR configuration) :
        if ar_jdbc_config[:pool] # default is 100
          hikari_config.setMaximumPoolSize ar_jdbc_config[:pool].to_i
          if prefill = ar_jdbc_config[:pool_prefill]
            hikari_config.setMinConnectionsPerPartition prefill.to_i
          end
        end

        checkout_timeout = ar_jdbc_config[:checkout_timeout] || 5
        hikari_config.setConnectionTimeout checkout_timeout * 1000

        hikari_config.setLeakDetectionThreshold 30 * 1000 # default 10s

        com.zaxxer.hikari.HikariDataSource.new hikari_config
      end
      private :configure_hikari_data_source

      def bind_data_source(data_source, jndi_name = jndi_config[:jndi])
        load_driver
        javax.naming.InitialContext.new.rebind jndi_name, data_source
      end

      def load_driver
        jdbc_driver_module.load_driver
      end

      def jdbc_driver_module
        driver = jndi_config[:adapter]
        driver = 'postgres' if driver == 'postgresql'
        driver = 'mysql'    if driver == 'mysql2'
        require "jdbc/#{driver}"
        ::Jdbc.const_get ::Jdbc.constants.first
      end

      def jndi_config
        @jndi_config ||= { :adapter => AR_CONFIG[:adapter], :jndi => jndi_name }
      end

      def jndi_name; 'jdbc/TestDB' end

      private

      def load_jar(jar)
        abs_jar = File.expand_path(jar)
        unless File.file?(abs_jar)
          raise "path does not exist or is not a file: #{jar}"
        end
        load abs_jar
      end

    end
  end
end
