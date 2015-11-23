require 'thread'
require 'monitor'

require 'active_record/connection_adapters/adapter_compat'
require 'active_record/bogacs/pool_support'
require 'active_record/bogacs/thread_safe'

module ActiveRecord
  module Bogacs

    # == Obtaining (checking out) a connection
    #
    # Connections can be obtained and used from a connection pool in several
    # ways:
    #
    # 1. Simply use ActiveRecord::Base.connection as with Active Record 2.1 and
    # earlier (pre-connection-pooling). Eventually, when you're done with
    # the connection(s) and wish it to be returned to the pool, you call
    # ActiveRecord::Base.clear_active_connections!.
    # 2. Manually check out a connection from the pool with
    # ActiveRecord::Base.connection_pool.checkout. You are responsible for
    # returning this connection to the pool when finished by calling
    # ActiveRecord::Base.connection_pool.checkin(connection).
    # 3. Use ActiveRecord::Base.connection_pool.with_connection(&block), which
    # obtains a connection, yields it as the sole argument to the block,
    # and returns it to the pool after the block completes.
    #
    # Connections in the pool are actually AbstractAdapter objects (or objects
    # compatible with AbstractAdapter's interface).
    #
    # == Options
    #
    # There are several connection-pooling-related options that you can add to
    # your database connection configuration:
    #
    # * **pool**: number indicating size of connection pool (default 5)
    # * **checkout_timeout**: number of seconds to block and wait for a connection
    # before giving up and raising a timeout error (default 5 seconds).
    # * **pool_initial**: number of connections to pre-initialize when the pool
    # is created (default 0).
    # * **reaping_frequency**: frequency in seconds to periodically run a reaper,
    # which attempts to find and close "dead" connections (can occur if a caller
    # forgets to close a connection at the end of a thread or a thread dies unexpectedly)
    # Default is `nil`, which means don't run the periodical Reaper at all (reaping
    # will still happen occasionally).
    class DefaultPool
      # Threadsafe, fair, FIFO queue. Meant to be used by ConnectionPool
      # with which it shares a Monitor. But could be a generic Queue.
      #
      # The Queue in stdlib's 'thread' could replace this class except
      # stdlib's doesn't support waiting with a timeout.
      # @private
      class Queue
        def initialize(lock)
          @lock = lock
          @cond = @lock.new_cond
          @num_waiting = 0
          @queue = []
        end

        # Test if any threads are currently waiting on the queue.
        def any_waiting?
          synchronize do
            @num_waiting > 0
          end
        end

        # Returns the number of threads currently waiting on this
        # queue.
        def num_waiting
          synchronize do
            @num_waiting
          end
        end

        # Add +element+ to the queue. Never blocks.
        def add(element)
          synchronize do
            @queue.push element
            @cond.signal
          end
        end

        # If +element+ is in the queue, remove and return it, or nil.
        def delete(element)
          synchronize do
            @queue.delete(element)
          end
        end

        # Remove all elements from the queue.
        def clear
          synchronize do
            @queue.clear
          end
        end

        # Remove the head of the queue.
        #
        # If +timeout+ is not given, remove and return the head the
        # queue if the number of available elements is strictly
        # greater than the number of threads currently waiting (that
        # is, don't jump ahead in line). Otherwise, return nil.
        #
        # If +timeout+ is given, block if it there is no element
        # available, waiting up to +timeout+ seconds for an element to
        # become available.
        #
        # Raises:
        # - ConnectionTimeoutError if +timeout+ is given and no element
        # becomes available after +timeout+ seconds,
        def poll(timeout = nil, &block)
          synchronize do
            if timeout
              no_wait_poll || wait_poll(timeout, &block)
            else
              no_wait_poll
            end
          end
        end

        private

        def synchronize(&block)
          @lock.synchronize(&block)
        end

        # Test if the queue currently contains any elements.
        def any?
          !@queue.empty?
        end

        # A thread can remove an element from the queue without
        # waiting if an only if the number of currently available
        # connections is strictly greater than the number of waiting
        # threads.
        def can_remove_no_wait?
          @queue.size > @num_waiting
        end

        # Removes and returns the head of the queue if possible, or nil.
        def remove
          @queue.shift
        end

        # Remove and return the head the queue if the number of
        # available elements is strictly greater than the number of
        # threads currently waiting. Otherwise, return nil.
        def no_wait_poll
          remove if can_remove_no_wait?
        end

        # Waits on the queue up to +timeout+ seconds, then removes and
        # returns the head of the queue.
        def wait_poll(timeout)
          t0 = Time.now
          elapsed = 0

          @num_waiting += 1

          yield if block_given?

          while true
            @cond.wait(timeout - elapsed)

            return remove if any?

            elapsed = Time.now - t0
            if elapsed >= timeout
              msg = 'could not obtain a database connection within %0.3f seconds (waited %0.3f seconds)' %
                [timeout, elapsed]
              raise ConnectionTimeoutError, msg
            end
          end
        ensure
          @num_waiting -= 1
        end
      end

      include PoolSupport
      include MonitorMixin # TODO consider avoiding ?!

      require 'active_record/bogacs/reaper.rb'

      attr_accessor :automatic_reconnect, :checkout_timeout
      attr_reader :spec, :connections, :size, :reaper
      attr_reader :initial_size

      # Creates a new ConnectionPool object. +spec+ is a ConnectionSpecification
      # object which describes database connection information (e.g. adapter,
      # host name, username, password, etc), as well as the maximum size for
      # this ConnectionPool.
      #
      # The default ConnectionPool maximum size is 5.
      def initialize(spec)
        super()

        @spec = spec

        @checkout_timeout = ( spec.config[:checkout_timeout] ||
            spec.config[:wait_timeout] || 5.0 ).to_f # <= 3.2 supports wait_timeout
        @reaper = Reaper.new self, spec.config[:reaping_frequency]
        @reaping = !! @reaper.run

        # default max pool size to 5
        if spec.config[:pool]
          @size = spec.config[:pool].to_i
        else
          if defined? Rails.env && ( (! Rails.env.development? && ! Rails.env.test?) rescue nil )
            logger && logger.debug("pool: option not set, using default size: 5")
          end
          @size = 5
        end

        # The cache of reserved connections mapped to threads
        @reserved_connections = ThreadSafe::Map.new(:initial_capacity => @size)

        @connections = []
        @automatic_reconnect = true

        @available = Queue.new self

        initial_size = spec.config[:pool_initial] || 0
        initial_size = @size if initial_size == true
        initial_size = (@size * initial_size).to_i if initial_size <= 1.0
        # NOTE: warn on onitial_size > size !
        prefill_initial_connections if ( @initial_size = initial_size.to_i ) > 0
      end

      # Retrieve the connection associated with the current thread, or call
      # #checkout to obtain one if necessary.
      #
      # #connection can be called any number of times; the connection is
      # held in a hash keyed by the thread id.
      #
      # @return [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      def connection
        connection_id = current_connection_id
        unless conn = @reserved_connections.fetch(connection_id, nil)
          synchronize do
            conn = ( @reserved_connections[connection_id] ||= checkout )
          end
        end
        conn
      end

      # Is there an open connection that is being used for the current thread?
      #
      # @return [true, false]
      def active_connection?
        connection_id = current_connection_id
        if conn = @reserved_connections.fetch(connection_id, nil)
          !! conn.in_use? # synchronize { conn.in_use? }
        else
          false
        end
      end

      # Signal that the thread is finished with the current connection.
      # #release_connection releases the connection-thread association
      # and returns the connection to the pool.
      def release_connection(with_id = current_connection_id)
        #synchronize do
          conn = @reserved_connections.delete(with_id)
          checkin conn, true if conn
        #end
      end

      # If a connection already exists yield it to the block. If no connection
      # exists checkout a connection, yield it to the block, and checkin the
      # connection when finished.
      #
      # @yield [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      def with_connection
        connection_id = current_connection_id
        fresh_connection = true unless active_connection?
        yield connection
      ensure
        release_connection(connection_id) if fresh_connection
      end

      # Returns true if a connection has already been opened.
      #
      # @return [true, false]
      def connected?
        @connections.size > 0 # synchronize { @connections.any? }
      end

      # Disconnects all connections in the pool, and clears the pool.
      def disconnect!
        synchronize do
          @reserved_connections.clear
          @connections.each do |conn|
            checkin conn
            conn.disconnect!
          end
          @connections.clear
          @available.clear
        end
      end

      # Clears the cache which maps classes.
      def clear_reloadable_connections!
        synchronize do
          @reserved_connections.clear
          @connections.each do |conn|
            checkin conn
            conn.disconnect! if conn.requires_reloading?
          end
          @connections.delete_if do |conn|
            conn.requires_reloading?
          end
          @available.clear
          @connections.each do |conn|
            @available.add conn
          end
        end
      end

      # Verify active connections and remove and disconnect connections
      # associated with stale threads.
      # @private AR 3.2 compatibility
      def verify_active_connections!
        synchronize do
          clear_stale_cached_connections!
          @connections.each do |connection|
            connection.verify!
          end
        end
      end if ActiveRecord::VERSION::MAJOR < 4

      # Return any checked-out connections back to the pool by threads that
      # are no longer alive.
      # @private AR 3.2 compatibility
      def clear_stale_cached_connections!
        keys = Thread.list.find_all { |t| t.alive? }.map(&:object_id)
        keys = @reserved_connections.keys - keys
        keys.each do |key|
          conn = @reserved_connections[key]
          checkin conn
          @reserved_connections.delete(key)
        end
      end if ActiveRecord::VERSION::MAJOR < 4

      # Check-out a database connection from the pool, callers are expected to
      # call #checkin when the connection is no longer needed, so that others
      # can use it.
      #
      # This is done by either returning and leasing existing connection, or by
      # creating a new connection and leasing it.
      #
      # @return [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      # @raise [ActiveRecord::ConnectionTimeoutError] if all connections are leased
      # and the pool is at capacity (meaning the number of currently leased
      # connections is greater than or equal to the size limit set)
      def checkout
        conn = nil
        synchronize do
          conn = acquire_connection
          conn.lease
        end
        checkout_and_verify(conn)
      end

      # Check-in a database connection back into the pool.
      #
      # @param [ActiveRecord::ConnectionAdapters::AbstractAdapter] connection
      # object, which was obtained earlier by calling #checkout on this pool
      # @see #checkout
      def checkin(conn, released = nil)
        synchronize do
          _run_checkin_callbacks(conn)

          release conn, conn.owner unless released

          @available.add conn
        end
      end

      # Remove a connection from the connection pool. The returned connection
      # will remain open and active but will no longer be managed by this pool.
      #
      # @return [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      def remove(conn)
        synchronize do
          @connections.delete conn
          @available.delete conn

          release conn, conn.owner

          @available.add checkout_new_connection if @available.any_waiting?
        end
      end

      # Recover lost connections for the pool. A lost connection can occur if
      # a caller forgets to #checkin a connection for a given thread when its done
      # or a thread dies unexpectedly.
      def reap
        stale_connections = synchronize do
          @connections.select do |conn|
            conn.in_use? && !conn.owner.alive?
          end
        end

        stale_connections.each do |conn|
          synchronize do
            if conn.active?
              conn.reset!
              checkin conn
            else
              remove conn
            end
          end
        end
      end
      # NOTE: active? and reset! are >= AR 2.3

      private

      # Acquire a connection by one of 1) immediately removing one
      # from the queue of available connections, 2) creating a new
      # connection if the pool is not at capacity, 3) waiting on the
      # queue for a connection to become available.
      #
      # Raises:
      # - ConnectionTimeoutError if a connection could not be acquired
      def acquire_connection
        if conn = @available.poll
          conn
        elsif @connections.size < @size
          checkout_new_connection
        else
          reap unless @reaping
          @available.poll(@checkout_timeout)
        end
      end

      def release(conn, owner)
        thread_id = owner.object_id
        if @reserved_connections[thread_id] == conn
          @reserved_connections.delete thread_id
        end
      end

      def checkout_new_connection
        raise ConnectionNotEstablished unless @automatic_reconnect

        conn = new_connection
        conn.pool = self
        @connections << conn
        conn
      end

      def checkout_and_verify(conn)
        _run_checkout_callbacks(conn)
        conn
      end

      def prefill_initial_connections
        conns = []; start = Time.now
        begin
          @initial_size.times { conns << checkout }
        ensure
          conns.each { |conn| checkin(conn) }
        end
        logger && logger.debug("pre-filled pool with #{@initial_size}/#{@size} connections in #{Time.now - start}")
        conns
      end

      #@@logger = nil
      def logger; ::ActiveRecord::Base.logger end
      #def logger=(logger); @@logger = logger end

    end

  end
end