ENV['DB_POOL'] = 10.to_s
ENV['DB_POOL_SHARED'] = 0.5.to_s

require File.expand_path('../../test_helper', File.dirname(__FILE__))

require 'active_record/basin/shareable_pool'

module ActiveRecord
  ConnectionAdapters::ConnectionPool.class_eval do
    attr_reader :available # the custom Queue
    attr_reader :reserved_connections # Thread-Cache
    # attr_reader :connections # created connections
  end
  Basin::ShareablePool.class_eval do
    attr_reader :shared_connections
  end
end

module ActiveRecord
  module Basin
    class ShareablePool

      module TestHelpers

        def teardown; connection_pool.disconnect! end

        def connection_pool
          ActiveRecord::Base.connection_pool
        end

        def initialized_connections
          ActiveRecord::Base.connection_pool.connections.dup
        end
        alias_method :connections, :initialized_connections

        def reserved_connections
          ActiveRecord::Base.connection_pool.reserved_connections
        end

        def available_connections
          connection_pool.available.instance_variable_get(:'@queue').dup
        end

        def available_connection? connection
          available_connections.include? connection
        end

        def shared_connections
          ActiveRecord::Base.connection_pool.shared_connections
        end

        def shared_connection? connection
          !!shared_connections.get(connection)
        end

        def with_shared_connection(&block)
          ActiveRecord::Base.connection_pool.with_shared_connection(&block)
        end

        def clear_active_connections!
          ActiveRecord::Base.clear_active_connections!
        end

        def clear_shared_connections!
          connection_pool = ActiveRecord::Base.connection_pool
          shared_connections.keys.each do |connection|
            connection_pool.release_shared_connection(connection)
          end
        end

      end

      class TestBase < ::Test::Unit::TestCase
        include TestHelpers

        def self.startup
          ConnectionAdapters::ConnectionHandler.connection_pool_class = ShareablePool

          ActiveRecord::Base.establish_connection AR_CONFIG
        end

        def self.shutdown
          ActiveRecord::Base.connection_pool.disconnect!
          ConnectionAdapters::ConnectionHandler.connection_pool_class = ConnectionAdapters::ConnectionPool
        end

      end

      class ConnectionPoolTest < TestBase

        include ConnectionAdapters::ConnectionPoolTestMethods

        def setup
          @pool = ShareablePool.new ActiveRecord::Base.connection_pool.spec
        end

      end

      class PoolAPITest < TestBase

        def setup; ActiveRecord::Base.connection end
        # def teardown; ActiveRecord::Base.connection_pool.reap end

        def test_is_setup
          assert ActiveRecord::Base.connection_pool.is_a? ShareablePool
        end

        def test_can_checkout_a_connection
          assert ActiveRecord::Base.connection.exec_query('SELECT 42')
        end

        def test_connected?
          assert ActiveRecord::Base.connected?
          begin
            ActiveRecord::Base.connection_pool.disconnect!
            assert ! ActiveRecord::Base.connected?
          ensure
            ActiveRecord::Base.connection
          end
        end

        def test_active?
          conn = ActiveRecord::Base.connection
          conn.exec_query('SELECT 42')
          assert conn.active?
          assert reserved_connections.size > 0
          begin
            ActiveRecord::Base.clear_active_connections!
            assert_equal 0, reserved_connections.size
          ensure
            ActiveRecord::Base.connection
          end
        end

        def test_disconnect!
          ActiveRecord::Base.connection
          threads = []
          threads << Thread.new { ActiveRecord::Base.connection }
          threads << Thread.new { ActiveRecord::Base.connection }
          threads.each(&:join)

          begin
            ActiveRecord::Base.connection_pool.disconnect!
            assert_equal 0, reserved_connections.size
            assert_equal 0, connections.size
            assert_equal 0, shared_connections.size
          ensure
            ActiveRecord::Base.connection
          end
        end

        def test_clear_reloadable_connections!
          ActiveRecord::Base.connection
          threads = []
          threads << Thread.new { ActiveRecord::Base.connection }
          threads << Thread.new { ActiveRecord::Base.connection }
          threads.each(&:join)

          begin
            ActiveRecord::Base.connection_pool.clear_reloadable_connections!
            assert_equal 0, reserved_connections.size
            assert connections.size > 0 # returned
            assert_equal 0, shared_connections.size
          ensure
            ActiveRecord::Base.connection
          end
        end

        def test_remove
          conn = ActiveRecord::Base.connection
          assert connections.include? conn
          begin
            connection_pool.remove(conn)
            refute connections.include?(conn)
            refute shared_connection?(conn)
          ensure
            ActiveRecord::Base.connection
          end
        end

      end

    end
  end
end
