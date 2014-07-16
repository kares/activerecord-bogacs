require 'bundler/setup'

# ENV variables supported :
# - AR_POOL=42 for testing out with higher pools
# - AR_POOL_CHECKOUT_TIMEOUT=2 for changing the pool connection acquire timeout
# - AR_POOL_PREFILL=10 how many connections to "prefill" the pool with on start
# - AR_POOL_SHARED=true/false or size/percentage (0.0-1.0) connection sharing
# - AR_PREPARED_STATEMENTS=true/false

connect_timeout = 5
checkout_timeout = 2.5 # default is to wait 5 seconds when all connections used
pool_size = 10
pool_prefill = 10 # (or simply true/false) how many connections to initialize
shared_pool = 0.75 # shareable pool true/false or size (integer or percentage)

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

config[:'pool'] = ENV['AR_POOL'] ? ENV['AR_POOL'].to_i : pool_size
config[:'shared_pool'] = shared_pool if shared_pool
config[:'connect_timeout'] = connect_timeout
prepared_statements = ENV['AR_PREPARED_STATEMENTS'] # || true
config[:'prepared_statements'] = prepared_statements if prepared_statements
#jdbc_properties = { 'logUnclosedConnections' => true, 'loginTimeout' => 5 }
#config['properties'] = jdbc_properties

checkout_timeout = ENV['AR_POOL_CHECKOUT_TIMEOUT'] || checkout_timeout
config[:'checkout_timeout'] = checkout_timeout.to_i if checkout_timeout

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
    autoload :ConnectionPoolTestMethods, 'active_record/connection_pool_test_methods'
  end
end