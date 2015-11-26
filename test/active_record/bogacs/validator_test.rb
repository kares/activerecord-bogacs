require File.expand_path('../../test_helper', File.dirname(__FILE__))
require 'stringio'

module ActiveRecord
  module Bogacs
    class ValidatorTest < Test::Unit::TestCase

      def self.startup
        ConnectionAdapters::ConnectionHandler.connection_pool_class = DefaultPool
      end

      def self.shutdown
        ConnectionAdapters::ConnectionHandler.connection_pool_class = nil
      end

      def config; AR_CONFIG end

      def teardown; @pool.disconnect! if (@pool ||= nil) end

      def test_null_validator
        pool = new_pool :validate_frequency => nil

        assert ! pool.validator?
        sleep 0.05
        assert ! pool.validating?
      end

      def test_parse_frequency
        pool = new_pool :validate_frequency => '0'

        assert ! pool.validator?
        sleep 0.05
        assert ! pool.validating?

        assert ! Validator.new(pool, '').frequency
        assert_equal 50, Validator.new(pool, '50').frequency
        assert_equal 5.5, Validator.new(pool, '5.5').frequency
      end

      def test_validator?
        assert pool.validator?
        sleep 0.1
        assert pool.validating?
      end

      require 'concurrent/atomic/atomic_fixnum.rb'
      AtomicFixnum = ::Concurrent::AtomicFixnum

      require 'concurrent/atomic/semaphore.rb'
      Semaphore = ::Concurrent::Semaphore

      def test_selects_non_used_connections
        assert_equal [], validator.send(:connections)

        count = AtomicFixnum.new
        semaphore = Semaphore.new(2); semaphore.drain_permits
        Thread.new {
          pool.with_connection { |conn| assert conn; count.increment; semaphore.acquire }
        }
        Thread.new {
          pool.with_connection { |conn| assert conn; count.increment; semaphore.acquire }
        }
        while count.value < 2; sleep 0.01 end

        released_conn = nil
        Thread.new {
          pool.with_connection { |conn| assert released_conn = conn }
        }.join


        assert_equal 3, pool.connections.size
        assert_equal 1, validator.send(:connections).size
        assert_equal [ released_conn ], validator.send(:connections)

        semaphore.release 2
      end

      def test_validate_connection
        conn = connection; pool.remove conn
        conn.expire; assert ! conn.in_use?
        # lazy on AR-JDBC :
        conn.tables; assert conn.active?

        def conn.active_called?; @_active_called ||= false end
        def conn.active?; @_active_called = true; super end

        result = validator.send :validate_connection, conn
        assert_true result

        assert conn.active_called?
      end

      def test_validate_connection_non_valid
        conn = connection; pool.remove conn
        conn.expire; assert ! conn.in_use?

        def conn.active?; false end

        result = validator.send :validate_connection, conn
        assert_false result
     end

      def test_validate_connection_in_use
        conn = connection
        assert  conn.in_use?
        def conn.active?; raise 'active? should not be called for a used connection' end

        result = validator.send :validate_connection, conn
        assert_nil result
      end

      def test_validate_connection_removes_invalid_connection_from_pool
        conn = connection
        puts pool.connections.map(&:object_id).inspect
        Thread.new { pool.with_connection { |conn| assert conn } }.join
        puts pool.connections.map(&:object_id).inspect
        assert_equal 2, pool.connections.size

        conn.expire; assert ! conn.in_use?

        def conn.active?; false end

        result = validator.send :validate_connection, conn
        assert_false result

        assert_equal 1, pool.connections.size
        assert ! pool.send(:connections).include?(conn)
      end

#      def test_reap_error_restart
#        logger = Logger.new str = StringIO.new
#        @pool.reaper.instance_variable_set :@logger, logger
#        def @pool.reap; raise RuntimeError, 'test_reap_error' end
#
#        assert @pool.reaper?
#        sleep 0.3
#        assert_true @pool.reaping?
#        assert_match /WARN.*reaping failed:.* test_reap_error.* restarting after/, str.string
#      end

      private

      def connection
        pool; ActiveRecord::Base.connection
      end

      def validator; pool.validator end

      def pool
        # self.startup: connection_pool_class = DefaultPool
        @pool ||= (establish_connection; Base.connection_pool)
      end

      DEFAULT_OPTS = { :size => 5, :validate_frequency => 1 }

      def establish_connection(opts = DEFAULT_OPTS)
        ActiveRecord::Base.establish_connection config.merge opts
      end

      def new_pool(opts = DEFAULT_OPTS)
        establish_connection config.merge opts
        DefaultPool.new Base.connection_pool.spec
      end

      class TimerTaskStub

        # :execution_interval => frequency, :timeout_interval => timeout
        def self.new(opts, &block)
          raise 'noop'
        end

      end

    end
  end
end