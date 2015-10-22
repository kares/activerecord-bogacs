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
    # * +pool+: number indicating size of connection pool (default 5)
    # * +checkout_timeout+: number of seconds to block and wait for a connection
    # before giving up and raising a timeout error (default 5 seconds).
    # * +reaping_frequency+: frequency in seconds to periodically run the
    # Reaper, which attempts to find and close dead connections, which can
    # occur if a programmer forgets to close a connection at the end of a
    # thread or a thread dies unexpectedly. (Default nil, which means don't
    # run the Reaper - reaping will still happen occasionally).
    class DefaultPool
      # Threadsafe, fair, FIFO queue. Meant to be used by ConnectionPool
      # with which it shares a Monitor. But could be a generic Queue.
      #
      # The Queue in stdlib's 'thread' could replace this class except
      # stdlib's doesn't support waiting with a timeout.
      # @private
      class Queue
        def initialize(lock = Monitor.new)
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

          loop do
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

      # Every +frequency+ seconds, the reaper will call +reap+ on +pool+.
      # A reaper instantiated with a nil frequency will never reap the
      # connection pool.
      #
      # Configure the frequency by setting "reaping_frequency" in your
      # database yaml file.
      class Reaper
        attr_reader :pool, :frequency

        def initialize(pool, frequency)
          @pool = pool
          @frequency = frequency
        end

        def run
          return unless frequency
          Thread.new(frequency, pool) { |t, p|
            while true
              sleep t
              p.reap
            end
          }
        end
      end

      include PoolSupport
      include MonitorMixin # TODO consider avoiding ?!

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
          if defined? Rails.env && Rails.env.production?
            logger && logger.debug("pool: option not set, using a default = 5")
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
      def with_connection
        connection_id = current_connection_id
        fresh_connection = true unless active_connection?
        yield connection
      ensure
        release_connection(connection_id) if fresh_connection
      end

      # Returns true if a connection has already been opened.
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
      def clear_stale_cached_connections!
        keys = Thread.list.find_all { |t| t.alive? }.map(&:object_id)
        keys = @reserved_connections.keys - keys
        keys.each do |key|
          conn = @reserved_connections[key]
          checkin conn
          @reserved_connections.delete(key)
        end
      end if ActiveRecord::VERSION::MAJOR < 4

      # Check-out a database connection from the pool, indicating that you want
      # to use it. You should call #checkin when you no longer need this.
      #
      # This is done by either returning and leasing existing connection, or by
      # creating a new connection and leasing it.
      #
      # If all connections are leased and the pool is at capacity (meaning the
      # number of currently leased connections is greater than or equal to the
      # size limit set), an ActiveRecord::ConnectionTimeoutError exception will be raised.
      #
      # Returns: an AbstractAdapter object.
      #
      # Raises:
      # - ConnectionTimeoutError: no connection can be obtained from the pool.
      def checkout
        synchronize do
          conn = acquire_connection
          conn.lease
          checkout_and_verify(conn)
        end
      end

      # Check-in a database connection back into the pool, indicating that you
      # no longer need this connection.
      #
      # +conn+: an AbstractAdapter object, which was obtained by earlier by
      # calling +checkout+ on this pool.
      def checkin(conn, released = nil)
        synchronize do
          conn.run_callbacks :checkin do
            conn.expire
          end

          release conn.owner unless released

          @available.add conn
        end
      end

      # Remove a connection from the connection pool. The connection will
      # remain open and active but will no longer be managed by this pool.
      def remove(conn)
        synchronize do
          @connections.delete conn
          @available.delete conn

          release conn.owner

          @available.add checkout_new_connection if @available.any_waiting?
        end
      end

      # Recover lost connections for the pool. A lost connection can occur if
      # a programmer forgets to checkin a connection at the end of a thread
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

      def release(owner)
        thread_id = owner.object_id
        @reserved_connections.delete thread_id
      end

      def checkout_new_connection
        raise ConnectionNotEstablished unless @automatic_reconnect

        c = new_connection
        c.pool = self
        @connections << c
        c
      end

      def checkout_and_verify(c)
        c.run_callbacks :checkout do
          c.verify!
        end
        c
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

      def logger
        ActiveRecord::Base.logger
      end

    end

=begin

    # ConnectionHandler is a collection of ConnectionPool objects. It is used
    # for keeping separate connection pools for Active Record models that connect
    # to different databases.
    #
    # For example, suppose that you have 5 models, with the following hierarchy:
    #
    # |
    # +-- Book
    # | |
    # | +-- ScaryBook
    # | +-- GoodBook
    # +-- Author
    # +-- BankAccount
    #
    # Suppose that Book is to connect to a separate database (i.e. one other
    # than the default database). Then Book, ScaryBook and GoodBook will all use
    # the same connection pool. Likewise, Author and BankAccount will use the
    # same connection pool. However, the connection pool used by Author/BankAccount
    # is not the same as the one used by Book/ScaryBook/GoodBook.
    #
    # Normally there is only a single ConnectionHandler instance, accessible via
    # ActiveRecord::Base.connection_handler. Active Record models use this to
    # determine the connection pool that they should use.
    class ConnectionHandler
      def initialize
        # These caches are keyed by klass.name, NOT klass. Keying them by klass
        # alone would lead to memory leaks in development mode as all previous
        # instances of the class would stay in memory.
        @owner_to_pool = ThreadSafe::Cache.new(:initial_capacity => 2) do |h,k|
          h[k] = ThreadSafe::Cache.new(:initial_capacity => 2)
        end
        @class_to_pool = ThreadSafe::Cache.new(:initial_capacity => 2) do |h,k|
          h[k] = ThreadSafe::Cache.new
        end
      end

      def connection_pool_list
        owner_to_pool.values.compact
      end

      def connection_pools
        ActiveSupport::Deprecation.warn(
          "In the next release, this will return the same as #connection_pool_list. " \
          "(An array of pools, rather than a hash mapping specs to pools.)"
        )
        Hash[connection_pool_list.map { |pool| [pool.spec, pool] }]
      end

      def establish_connection(owner, spec)
        @class_to_pool.clear
        raise RuntimeError, "Anonymous class is not allowed." unless owner.name
        owner_to_pool[owner.name] = ConnectionAdapters::ConnectionPool.new(spec)
      end

      # Returns true if there are any active connections among the connection
      # pools that the ConnectionHandler is managing.
      def active_connections?
        connection_pool_list.any?(&:active_connection?)
      end

      # Returns any connections in use by the current thread back to the pool,
      # and also returns connections to the pool cached by threads that are no
      # longer alive.
      def clear_active_connections!
        connection_pool_list.each(&:release_connection)
      end

      # Clears the cache which maps classes.
      def clear_reloadable_connections!
        connection_pool_list.each(&:clear_reloadable_connections!)
      end

      def clear_all_connections!
        connection_pool_list.each(&:disconnect!)
      end

      # Locate the connection of the nearest super class. This can be an
      # active or defined connection: if it is the latter, it will be
      # opened and set as the active connection for the class it was defined
      # for (not necessarily the current class).
      def retrieve_connection(klass) #:nodoc:
        pool = retrieve_connection_pool(klass)
        (pool && pool.connection) or raise ConnectionNotEstablished
      end

      # Returns true if a connection that's accessible to this class has
      # already been opened.
      def connected?(klass)
        conn = retrieve_connection_pool(klass)
        conn && conn.connected?
      end

      # Remove the connection for this class. This will close the active
      # connection and the defined connection (if they exist). The result
      # can be used as an argument for establish_connection, for easily
      # re-establishing the connection.
      def remove_connection(owner)
        if pool = owner_to_pool.delete(owner.name)
          @class_to_pool.clear
          pool.automatic_reconnect = false
          pool.disconnect!
          pool.spec.config
        end
      end

      # Retrieving the connection pool happens a lot so we cache it in @class_to_pool.
      # This makes retrieving the connection pool O(1) once the process is warm.
      # When a connection is established or removed, we invalidate the cache.
      #
      # Ideally we would use #fetch here, as class_to_pool[klass] may sometimes be nil.
      # However, benchmarking (https://gist.github.com/jonleighton/3552829) showed that
      # #fetch is significantly slower than #[]. So in the nil case, no caching will
      # take place, but that's ok since the nil case is not the common one that we wish
      # to optimise for.
      def retrieve_connection_pool(klass)
        class_to_pool[klass.name] ||= begin
          until pool = pool_for(klass)
            klass = klass.superclass
            break unless klass <= Base
          end

          class_to_pool[klass.name] = pool
        end
      end

      private

      def owner_to_pool
        @owner_to_pool[Process.pid]
      end

      def class_to_pool
        @class_to_pool[Process.pid]
      end

      def pool_for(owner)
        owner_to_pool.fetch(owner.name) {
          if ancestor_pool = pool_from_any_process_for(owner)
            # A connection was established in an ancestor process that must have
            # subsequently forked. We can't reuse the connection, but we can copy
            # the specification and establish a new connection with it.
            establish_connection owner, ancestor_pool.spec
          else
            owner_to_pool[owner.name] = nil
          end
        }
      end

      def pool_from_any_process_for(owner)
        owner_to_pool = @owner_to_pool.values.find { |v| v[owner.name] }
        owner_to_pool && owner_to_pool[owner.name]
      end
    end

    class ConnectionManagement
      def initialize(app)
        @app = app
      end

      def call(env)
        testing = env.key?('rack.test')

        response = @app.call(env)
        response[2] = ::Rack::BodyProxy.new(response[2]) do
          ActiveRecord::Base.clear_active_connections! unless testing
        end

        response
      rescue Exception
        ActiveRecord::Base.clear_active_connections! unless testing
        raise
      end
    end

=end

  end
end