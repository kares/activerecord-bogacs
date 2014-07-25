require File.expand_path('../shareable_pool_helper', File.dirname(__FILE__))

module ActiveRecord
  module Bogacs
    class ShareablePool

      class ConnectionPoolTest < TestBase

        include ConnectionAdapters::ConnectionPoolTestMethods

        def setup
          @pool = ShareablePool.new ActiveRecord::Base.connection_pool.spec
        end

        if ActiveRecord::VERSION::MAJOR < 4
          # TODO override with similar (back-ported) tests :
          undef :test_remove_connection
          undef :test_remove_connection_for_thread
          undef :test_removing_releases_latch

          undef :test_reap_and_active
          undef :test_reap_inactive
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
        end if ActiveRecord::VERSION::MAJOR >= 4

      end

      class PoolAPIWithSharedConnectionTest < PoolAPITest

        def setup
          with_shared_connection do
            @shared_connection = ActiveRecord::Base.connection
          end
        end

        def teardown
          connection_pool.release_shared_connection(@shared_connection)
          super
        end

      end

      class CustomAPITest < TestBase

        def setup
          connection_pool.disconnect!
        end

        def teardown
          clear_active_connections!; clear_shared_connections!
        end

        def test_with_shared_connection
          shared_connection = nil
          assert shared_connections.empty?
          begin
            with_shared_connection do |connection|
              assert shared_connection = connection
              assert shared_connections.get(connection)
              assert connections.include?(connection)
            end
          ensure
            connection_pool.remove(shared_connection) if shared_connection
          end
        end

        def test_with_shared_connection_disconnected
          shared_connection = nil
          begin
            connections_size = connections.size
            with_shared_connection do |connection|
              assert shared_connection = connection
              assert shared_connection?(connection)
              assert_equal connections_size + 1, connections.size
            end
          ensure
            connection_pool.remove(shared_connection) if shared_connection
            ActiveRecord::Base.connection
          end
        end

        def test_release_shared_connection
          begin
            with_shared_connection do |connection|
              assert shared_connection?(connection)
              refute available_connection?(connection)

              connection_pool.release_shared_connection(connection)

              refute shared_connection?(connection)
              assert available_connection?(connection)
            end
          ensure
            connection_pool.disconnect!
            ActiveRecord::Base.connection
          end
        end

      end

    end
  end
end
