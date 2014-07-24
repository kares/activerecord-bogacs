require File.expand_path('../../test_helper', File.dirname(__FILE__))

require 'atomic'

ActiveRecord::Bogacs::FalsePool.class_eval do
  # ...
end

module ActiveRecord
  module Bogacs
    class FalsePool

      class TestBase < ::Test::Unit::TestCase
        # extend Bogacs::TestHelper
        extend Bogacs::JndiTestHelper

        def self.startup
          return if self == TestBase

          ActiveRecord::Base.establish_connection AR_CONFIG

          ActiveRecord::Base.connection.jdbc_connection # force connection
          current_config = Bogacs::TestHelper.current_connection_config

          ActiveRecord::Base.connection_pool.disconnect!

          setup_jdbc_context
          bind_data_source init_data_source current_config

          ConnectionAdapters::ConnectionHandler.connection_pool_class = FalsePool
          ActiveRecord::Base.establish_connection jndi_config
        end

        def self.shutdown
          return if self == TestBase

          ActiveRecord::Base.connection_pool.disconnect!
          ConnectionAdapters::ConnectionHandler.connection_pool_class = ConnectionAdapters::ConnectionPool
        end

      end

      class ConnectionPoolWrappingTomcatJdbcTest < TestBase

        @@data_source = nil
        def self.init_data_source(config)
          @@data_source = init_tomcat_jdbc_data_source(config)
        end

#        include ConnectionAdapters::ConnectionPoolTestMethods

        def setup
          @pool = FalsePool.new ActiveRecord::Base.connection_pool.spec
        end

        def test_uses_false_pool_and_can_execute_query
          assert_instance_of ActiveRecord::Bogacs::FalsePool, ActiveRecord::Base.connection_pool
          assert ActiveRecord::Base.connection.exec_query('SELECT 42')
        end

        # adjust ConnectionAdapters::ConnectionPoolTestMethods :

#        undef :test_checkout_fairness
#        undef :test_checkout_fairness_by_group
#
#        undef :test_released_connection_moves_between_threads
#
#        undef :test_reap_inactive
#
#        undef :test_automatic_reconnect= # or does automatic_reconnect make sense?
#
#        # @override
#        def test_remove_connection
#          conn = pool.checkout
#          assert conn.in_use?
#
#          #length = pool.connections.size
#          pool.remove conn
#          assert conn.in_use?
#          #assert_equal(length - 1, pool.connections.length)
#        ensure
#          conn.close if conn
#        end

        # @override
        def test_full_pool_blocks
          t1_ready = Queue.new; t1_block = Queue.new
          t1 = Thread.new do
            begin
              conn = ActiveRecord::Base.connection
              t1_ready.push(conn)
              t1_block.pop # await
            rescue => e
              puts "t1 thread failed: #{e.inspect}"
            ensure
              conn && conn.close
            end
          end

          threads_ready = Queue.new; threads_block = Atomic.new(0); threads = []
          (pool_size - 1).times do |i|
            threads << Thread.new do
              begin
                conn = ActiveRecord::Base.connection
                threads_block.update { |v| v + 1 }
                threads_ready << i
                while threads_block.value != -1 # await
                  sleep(0.005)
                end
              rescue => e
                puts "block thread failed: #{e.inspect}"
              ensure
                conn && conn.close
              end
            end
          end
          (pool_size - 1).times { threads_ready.pop } # awaits

          connection = t1_ready.pop
          t1_jdbc_connection = connection.jdbc_connection(true)

          # pool = ActiveRecord::Base.connection_pool

          t2 = Thread.new do
            begin
              ActiveRecord::Base.connection
            rescue => e
              puts "t2 thread failed: #{e.inspect}"
            end
          end; sleep(0.1)

          # make sure our thread is in the timeout section
          # Thread.pass until t2.status == "sleep"

          sleep(0.02); assert t2.alive?
          sleep(0.03); assert t2.alive?

          t1_block.push(:release); t1.join

          sleep(0.01); assert_not_equal 'sleep', t2.status

          if defined? JRUBY_VERSION
            if connection2 = t2.join.value
              assert_equal t1_jdbc_connection, connection2.jdbc_connection(true)
            end
          end

        ensure
          #connection && connection.close
          threads_block && threads_block.swap(-1)
          threads && threads.each(&:join)
        end

        private

        def pool_size; @@data_source.max_active end

      end

    end
  end
end