require File.expand_path('../shareable_pool_helper', File.dirname(__FILE__))

module ActiveRecord
  module Bogacs
    class ShareablePool

      # TODO: ShareablePool is pretty much broken since 0.7 :
      class ConnectionSharingTest #< TestBase
        include TestHelper

        def setup
          connection_pool.disconnect!
          @_pool_size = set_pool_size(10, 5)
        end

        def teardown
          clear_active_connections!; clear_shared_connections!
          set_pool_size(*@_pool_size)
        end

        def test_do_not_share_if_theres_an_active_connection
          existing_conn = ActiveRecord::Base.connection
          begin
            with_shared_connection do |connection|
              assert connection
              refute shared_connection?(connection)
              assert_nil current_shared_pool_connection
              assert_equal existing_conn, ActiveRecord::Base.connection
            end
            assert_equal existing_conn, ActiveRecord::Base.connection
          end
        end

        def test_acquires_new_shared_connection_if_none_active
          begin
            with_shared_connection do |connection|
              assert shared_connection?(connection)
              assert_equal connection, current_shared_pool_connection

              assert_equal connection, ActiveRecord::Base.connection # only during block
            end
            assert_nil current_shared_pool_connection
            # - they actually might be the same - no need to check-out a new :
            # refute_equal shared_connection, ActiveRecord::Base.connection
          end
        end

        def test_acquires_new_shared_connection_if_none_active_with_nested_block
          begin
            with_shared_connection do |connection|
              assert shared_connection?(connection)
              assert_equal connection, current_shared_pool_connection

              assert_equal connection, ActiveRecord::Base.connection # only during block

              # test nested block :
              with_shared_connection do |connection2|
                assert_equal connection, connection2
                assert_equal connection2, current_shared_pool_connection
              end
              assert_equal connection, current_shared_pool_connection
            end
            assert_nil current_shared_pool_connection
          end
        end

        def test_acquires_same_shared_connection_for_two_threads_when_pool_occupied
          thread_connection = Atomic.new(nil); shared_thread = nil
          begin
            shared_connection = nil
            block_connections_in_threads(9) do # only one connection left

              shared_thread = shared_connection_thread(thread_connection, :wait)

              with_shared_connection do |connection|
                shared_connection = connection

                assert shared_connection?(connection)
                assert_equal connection, current_shared_pool_connection

                # just test that selects are fine :
                connection.exec_query(sample_query)

                assert_equal connection, thread_connection.value
              end
              assert_nil current_shared_pool_connection
            end

            refute_equal shared_connection, ActiveRecord::Base.connection

          ensure
            stop_shared_connection_threads thread_connection => shared_thread
          end
        end

        def test_shared_connections_get_reused_fairly
          thread1_holder = Atomic.new(nil)
          thread2_holder = Atomic.new(nil)
          thread3_holder = Atomic.new(nil)
          shared_conn_threads = {}
          begin
            block_connections_in_threads(8) do # only 2 (shareable) connections left

              #puts "\nshared_conn thread 1"
              shared_conn_threads[thread1_holder] =
                shared_connection_thread(thread1_holder, :wait)
              shared_conn1 = thread1_holder.value

              #puts "\nAR-BASE with_shared 1"
              with_shared_connection do |connection|
                assert shared_connection?(connection)
                # here it should checkout a new connection from the pool
                assert connection != shared_conn1, '' << # connection == shared_conn2
                  "with_shared_connection reused a previously shared connection " <<
                  "instead of checking out another from the (non-filled) pool"
                # just test that selects are fine :
                connection.exec_query(sample_query)
              end
              #puts "AR-BASE with_shared 1 DONE"

              #puts "\nshared_conn thread 2"
              shared_conn_threads[thread2_holder] =
                shared_connection_thread(thread2_holder, :wait)
              shared_conn2 = thread2_holder.value
              assert shared_conn2 != shared_conn1, "shared connections are same"

              #puts "\nAR-BASE with_shared 2"
              with_shared_connection do |connection|
                assert shared_connection?(connection)

                #puts "\n - shared_conn thread 3"
                shared_conn_threads[thread3_holder] =
                  shared_connection_thread(thread3_holder, :wait)
                shared_conn3 = thread3_holder.value

                # but now it needs to reuse since pool "full" :
                if connection != shared_conn1
                  assert_equal connection, shared_conn2

                  assert shared_conn3 == shared_conn1,
                    "expected thread3's connection #{shared_conn3.to_s} to == " <<
                    "#{shared_conn1.to_s} (but did not thread2's connection = #{shared_conn2.to_s})"
                else
                  assert shared_conn3 == shared_conn2,
                    "expected thread3's connection #{shared_conn3.to_s} to == " <<
                    "#{shared_conn2.to_s} (but did not thread1's connection = #{shared_conn1.to_s})"
                end
              end
              #puts "AR-BASE with_shared 2 DONE"
            end
          ensure
            stop_shared_connection_threads shared_conn_threads
          end
        end

        def test_shared_connections_get_reused_fairly_with_pool_prefilled
          prefill_pool_with_connections
          test_shared_connections_get_reused_fairly
        end

        def test_does_not_use_more_shared_connections_than_configured_shared_size
          shared_conn_threads = {}
          begin
            block_connections_in_threads(4) do # 6 (out of 10) connections left

              shared_conn_threads = start_shared_connection_threads(7, :wait)

              # 10 connections but shared pool is limited to max 50% :
              shared_conns = shared_conn_threads.keys.map do |conn_holder|
                assert conn = conn_holder.value
                assert shared_connection?(conn)
                conn
              end

              assert_equal 5, shared_conns.uniq.size

              # still one left for normal connections :
              assert_equal 9, connection_pool.connections.size

              conn = ActiveRecord::Base.connection
              refute shared_connection?(conn)
              assert_equal 10, connection_pool.connections.size

            end
          ensure # release created threads
            stop_shared_connection_threads shared_conn_threads
          end
        end

        def test_starts_blocking_when_sharing_max_is_reached
          shared_conn_threads = {}
          begin
            block_connections_in_threads(6) do # assuming pool size 10

              shared_conn_threads = start_shared_connection_threads(20, :wait)

              # getting another one will block - timeout error :
              assert_raise ActiveRecord::ConnectionTimeoutError do
                with_shared_connection do |connection|
                  flunk "not expected to get a shared-connection"
                end
              end
            end
          ensure # release created threads
            stop_shared_connection_threads shared_conn_threads
          end
        end

        def test_starts_blocking_when_sharing_max_is_reached_with_pool_prefilled
          prefill_pool_with_connections
          test_starts_blocking_when_sharing_max_is_reached
        end

        def test_releases_shared_connections_back_as_blocks_are_done
          block_connections_in_threads(5) do # assuming pool size 10
            assert_equal 5, initialized_connections.size
            shared_conn_threads = start_shared_connection_threads(20, false) # no :wait
            # ... 5 threads shared ~ 4-times - still have 5 "left"
            begin
              threads = []

              stop_condition = Atomic.new(false)
              4.times do
                threads << Thread.new(self) do |test|
                  test.with_shared_connection do
                    sleep(0.005) while ( ! stop_condition.value )
                  end
                end
              end

              sleep(0.01)

              with_shared_connection do |conn1|
                assert shared_connection? conn1

                conns = shared_conn_threads.keys.map do |holder|
                  sleep(0.001) while ! holder.value
                  assert shared_connection? holder.value
                  holder.value # the connection
                end
                assert_equal 20, conns.size
                assert_equal  5, conns.uniq.size

                sleep(0.005)

                with_shared_connection do |conn2|
                  assert conn1 == conn2

                  # we can not do any-more here without a timeout :
                  failed = nil
                  Thread.new(self) do |test|
                    begin
                      test.with_shared_connection { failed = false }
                    rescue => e
                      failed = e
                    end
                  end.join
                  #assert failed
                  assert_instance_of ActiveRecord::ConnectionTimeoutError, failed

                  stop_condition.swap(true); threads.each(&:join); threads = []

                  # but now we released 4 "shared" connections :
                  stop_condition.swap(false)

                  failures = []
                  4.times do
                    threads << Thread.new(self) do |test|
                      begin
                        test.with_shared_connection do
                          ActiveRecord::Base.connection.exec_query test_query # 'select 42'
                          sleep(0.005) while ( ! stop_condition.value )
                        end
                      rescue => e
                        failures << e
                      end
                    end
                  end

                  stop_condition.swap(true); threads.each(&:join); threads = []
                  assert failures.empty?, "got failures: #{failures.map(&:inspect).join}"

                end # nested with_shared_connection
              end # with_shared_connection

            ensure
              stop_shared_connection_threads shared_conn_threads
            end
          end
        end

        protected

        def current_shared_pool_connection
          Thread.current[ connection_pool.send(:shared_connection_key) ]
        end

        def set_pool_size(size, shared_size = nil)
          prev_size = connection_pool.size
          prev_shared_size = connection_pool.shared_size
          connection_pool.size = size
          connection_pool.shared_size = shared_size if shared_size
          if block_given?
            begin
              yield
            ensure
              connection_pool.size = prev_size
              connection_pool.shared_size = prev_shared_size
            end
          else
            shared_size ? [ prev_size, prev_shared_size ] : prev_size
          end
        end

        def set_shared_size(size)
          prev_size = connection_pool.shared_size
          connection_pool.shared_size = size
          if block_given?
            begin
              yield
            ensure
              connection_pool.shared_size = prev_size
            end
          else
            prev_size
          end
        end

        private

        @@counter = 0
        STDOUT.sync = true

        def shared_connection_thread(connection_holder, wait = true)
          test_name = _test_name

          debug = test_name == 'test_starts_blocking_when_sharing_max_is_reached_with_pool_prefilled'
          if debug && false
            @@counter += 1
            puts "\n"
            puts "#{@@counter} initialized-connections: #{connections.size}"
            puts "#{@@counter} shared-connections: #{shared_connections.size}"
            puts "#{@@counter} available-connections #{available_connections.size}"
            puts "#{@@counter} reserved-connections #{reserved_connections.size}"
            puts "\n"
          end

          thread = Thread.new do
            begin
              ActiveRecord::Base.connection_pool.with_shared_connection do |connection|
                # just test that selects are fine :
                connection.exec_query(test_query)

                connection_holder.swap(connection)
                while connection_holder.value != false
                  # connection.select_value('SELECT version()')
                  sleep(0.001)
                end
                # just test that selects are fine :
                connection.select_value(sample_query)
              end
            rescue => e
              puts "\n#{test_name} acquire shared thread failed: #{e.inspect} \n  #{e.backtrace.join("  \n")}\n"
            end
          end

          while connection_holder.value.nil?
            sleep(0.005)
          end if wait

          thread
        end

        def start_shared_connection_threads(count, wait = true)
          holder_2_thread = {}
          count.times do
            conn_holder = Atomic.new(nil)
            thread = shared_connection_thread(conn_holder, wait)
            holder_2_thread[conn_holder] = thread
          end
          holder_2_thread
        end

        def stop_shared_connection_threads(holder_2_threads)
          holder_2_threads.keys.each { |holder| holder.swap(false) }
          holder_2_threads.values.each(&:join)
        end

        def block_connections_in_threads(count)
          block = Atomic.new(0); threads = []
          count.times do
            threads << Thread.new do
              begin
                ActiveRecord::Base.connection
                block.update { |v| v + 1 }
                while block.value <= count
                  sleep(0.005)
                end
              rescue => e
                puts "block thread failed: #{e.inspect}"
              ensure
                ActiveRecord::Base.clear_active_connections!
              end
            end
          end

          while block.value < count
            sleep(0.001) # wait till connections are blocked
          end

          outcome = yield

          block.update { |v| v + 42 }; threads.each(&:join)

          outcome
        end

        def prefill_pool_with_connections(size = connection_pool.size)
          conns = []
          begin
            size.times { conns << connection_pool.checkout }
          ensure
            conns.each { |conn| connection_pool.checkin(conn) }
          end
        end

      end

    end
  end
end
