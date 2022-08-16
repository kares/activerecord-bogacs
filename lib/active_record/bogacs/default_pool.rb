require 'active_record/version'

require 'thread'
require 'monitor'
require 'concurrent/atomic/atomic_boolean'

require 'active_record/connection_adapters/adapter_compat'
require 'active_record/bogacs/pool_support'
require 'active_record/bogacs/thread_safe'

module ActiveRecord
  module Bogacs

    # A "default" `ActiveRecord::ConnectionAdapters::ConnectionPool`-like pool
    # implementation with compatibility across (older) Rails versions.
    #
    # Currently, mostly, based on ActiveRecord **4.2**.
    #
    # http://api.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/ConnectionPool.html
    #
    class DefaultPool

      # @private
      class Queue # ConnectionLeasingQueue
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
        # @raise [ActiveRecord::ConnectionTimeoutError] if +timeout+ given and no element
        # becomes available after +timeout+ seconds
        def poll(timeout = nil)
          synchronize { internal_poll(timeout) }
        end

        private

        def internal_poll(timeout)
          conn = no_wait_poll || (timeout && wait_poll(timeout))
          # Connections must be leased while holding the main pool mutex. This is
          # an internal subclass that also +.leases+ returned connections while
          # still in queue's critical section (queue synchronizes with the same
          # <tt>@lock</tt> as the main pool) so that a returned connection is already
          # leased and there is no need to re-enter synchronized block.
          #
          # NOTE: avoid the need for ConnectionLeasingQueue, since BiasableQueue is not implemented
          conn.lease if conn
          conn
        end

        def synchronize(&block)
          @lock.synchronize(&block)
        end

        # Test if the queue currently contains any elements.
        def any?
          !@queue.empty?
        end

        # A thread can remove an element from the queue without
        # waiting if and only if the number of currently available
        # connections is strictly greater than the number of waiting
        # threads.
        def can_remove_no_wait?
          @queue.size > @num_waiting
        end

        # Removes and returns the head of the queue if possible, or +nil+.
        def remove
          @queue.pop
        end

        # Remove and return the head the queue if the number of
        # available elements is strictly greater than the number of
        # threads currently waiting.  Otherwise, return +nil+.
        def no_wait_poll
          remove if can_remove_no_wait?
        end

        # Waits on the queue up to +timeout+ seconds, then removes and
        # returns the head of the queue.
        def wait_poll(timeout)
          @num_waiting += 1

          t0 = Time.now
          elapsed = 0
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
      attr_reader :spec, :size, :reaper
      attr_reader :validator, :initial_size

      # Creates a new `ConnectionPool` object. +spec+ is a ConnectionSpecification
      # object which describes database connection information (e.g. adapter,
      # host name, username, password, etc), as well as the maximum size for
      # this ConnectionPool.
      #
      # @note The default ConnectionPool maximum size is **5**.
      #
      # @param [Hash] spec a `ConnectionSpecification`
      #
      # @option spec.config [Integer] :pool number indicating size of connection pool (default 5)
      # @option spec.config [Float] :checkout_timeout number of seconds to block and
      # wait for a connection before giving up raising a timeout (default 5 seconds).
      # @option spec.config [Integer] :pool_initial number of connections to pre-initialize
      # when the pool is created (default 0).
      # @option spec.config [Float] :reaping_frequency frequency in seconds to periodically
      # run a reaper, which attempts to find and close "dead" connections (can occur
      # if a caller forgets to close a connection at the end of a thread or a thread
      # dies unexpectedly) default is `nil` - don't run the periodical Reaper (reaping
      # will still happen occasionally).
      # @option spec.config [Float] :validate_frequency frequency in seconds to periodically
      # run a connection validation (in a separate thread), to avoid potentially stale
      # sockets when connections stay open (pooled but unused) for longer periods.
      def initialize(spec)
        super()

        @spec = spec

        @checkout_timeout = ( spec.config[:checkout_timeout] || 5 ).to_f
        if @idle_timeout = spec.config.fetch(:idle_timeout, 300)
          @idle_timeout = @idle_timeout.to_f
          @idle_timeout = nil if @idle_timeout <= 0
        end

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
        @thread_cached_conns = ThreadSafe::Map.new(initial_capacity: @size)

        @connections = []
        @automatic_reconnect = true

        # Connection pool allows for concurrent (outside the main +synchronize+ section)
        # establishment of new connections. This variable tracks the number of threads
        # currently in the process of independently establishing connections to the DB.
        @now_connecting = 0

        @threads_blocking_new_connections = 0 # TODO: dummy for now

        @available = Queue.new self

        @lock_thread = false

        @connected = ::Concurrent::AtomicBoolean.new

        initial_size = spec.config[:pool_initial] || 0
        initial_size = @size if initial_size == true
        initial_size = (@size * initial_size).to_i if initial_size <= 1.0
        # NOTE: warn on onitial_size > size !
        prefill_initial_connections if ( @initial_size = initial_size.to_i ) > 0

        if frequency = spec.config[:validate_frequency]
          require 'active_record/bogacs/validator' unless self.class.const_defined?(:Validator)
          @validator = Validator.new self, frequency, spec.config[:validate_timeout]
          if @validator.run && @reaping
            logger && logger.warn(":validate_frequency configured alongside with :reaping_frequency")
          end
        end
      end

      # Retrieve the connection associated with the current thread, or call
      # #checkout to obtain one if necessary.
      #
      # #connection can be called any number of times; the connection is
      # held in a hash keyed by the thread id.
      #
      # @return [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      def connection
        connection_id = connection_cache_key(current_thread)
        conn = @thread_cached_conns.fetch(connection_id, nil)
        conn = ( @thread_cached_conns[connection_id] ||= checkout ) unless conn
        conn
      end

      # Is there an open connection that is being used for the current thread?
      #
      # @return [true, false]
      def active_connection?
        connection_id = connection_cache_key(current_thread)
        @thread_cached_conns.fetch(connection_id, nil)
      end

      # Signal that the thread is finished with the current connection.
      # #release_connection releases the connection-thread association
      # and returns the connection to the pool.
      def release_connection(owner_thread = Thread.current)
        conn = @thread_cached_conns.delete(connection_cache_key(owner_thread))
        checkin conn if conn
      end

      # If a connection already exists yield it to the block. If no connection
      # exists checkout a connection, yield it to the block, and checkin the
      # connection when finished.
      #
      # @yield [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      def with_connection
        connection_id = connection_cache_key
        unless conn = @thread_cached_conns[connection_id]
          conn = connection
          fresh_connection = true
        end
        yield conn
      ensure
        release_connection if fresh_connection
      end

      # Returns true if a connection has already been opened.
      #
      # @return [true, false]
      def connected?
        @connected.true? # synchronize { @connections.any? }
      end

      # Returns an array containing the connections currently in the pool.
      # Access to the array does not require synchronization on the pool because
      # the array is newly created and not retained by the pool.
      #
      # However; this method bypasses the ConnectionPool's thread-safe connection
      # access pattern. A returned connection may be owned by another thread,
      # unowned, or by happen-stance owned by the calling thread.
      #
      # Calling methods on a connection without ownership is subject to the
      # thread-safety guarantees of the underlying method. Many of the methods
      # on connection adapter classes are inherently multi-thread unsafe.
      def connections
        synchronize { @connections.dup }
      end

      # Disconnects all connections in the pool, and clears the pool.
      def disconnect!
        synchronize do
          @connected.make_false

          @thread_cached_conns.clear
          @connections.each do |conn|
            if conn.in_use?
              conn.steal!
              checkin conn
            end
            conn.disconnect!
          end
          @connections.clear
          @available.clear
        end
      end

      # Discards all connections in the pool (even if they're currently
      # leased!), along with the pool itself. Any further interaction with the
      # pool (except #spec and #schema_cache) is undefined.
      #
      # See AbstractAdapter#discard!
      def discard! # :nodoc:
        synchronize do
          return if discarded?
          @connected.make_false

          @connections.each do |conn|
            conn.discard!
          end
          @connections = @available = @thread_cached_conns = nil
        end
      end

      def discarded? # :nodoc:
        @connections.nil?
      end

      def clear_reloadable_connections!
        synchronize do
          @thread_cached_conns.clear
          @connections.each do |conn|
            if conn.in_use?
              conn.steal!
              checkin conn
            end
            conn.disconnect! if conn.requires_reloading?
          end
          @connections.delete_if(&:requires_reloading?)
          @available.clear
          @connections.each do |conn|
            @available.add conn
          end

          @connected.value = @connections.any?
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
        keys = @thread_cached_conns.keys - keys
        keys.each do |key|
          conn = @thread_cached_conns[key]
          checkin conn
          @thread_cached_conns.delete(key)
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
      def checkout(checkout_timeout = @checkout_timeout)
        checkout_and_verify(acquire_connection(checkout_timeout))
      end

      # Check-in a database connection back into the pool, indicating that you
      # no longer need this connection.
      #
      # +conn+: an AbstractAdapter object, which was obtained by earlier by
      # calling #checkout on this pool.
      def checkin(conn)
        #conn.lock.synchronize do
        synchronize do
          remove_connection_from_thread_cache conn

          _run_checkin_callbacks(conn)

          @available.add conn
        end
        #end
      end

      # Remove a connection from the connection pool. The returned connection
      # will remain open and active but will no longer be managed by this pool.
      #
      # @return [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      def remove(conn)
        needs_new_connection = false

        synchronize do
          remove_connection_from_thread_cache conn

          @connections.delete conn
          @available.delete conn

          @connected.value = @connections.any?

          needs_new_connection = @available.any_waiting?
        end

        # This is intentionally done outside of the synchronized section as we
        # would like not to hold the main mutex while checking out new connections.
        # Thus there is some chance that needs_new_connection information is now
        # stale, we can live with that (bulk_make_new_connections will make
        # sure not to exceed the pool's @size limit).
        bulk_make_new_connections(1) if needs_new_connection
      end

      # Recover lost connections for the pool. A lost connection can occur if
      # a caller forgets to #checkin a connection for a given thread when its done
      # or a thread dies unexpectedly.
      def reap
        stale_connections = synchronize do
          @connections.select do |conn|
            conn.in_use? && !conn.owner.alive?
          end.each do |conn|
            conn.steal!
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

      # Disconnect all connections that have been idle for at least
      # +minimum_idle+ seconds. Connections currently checked out, or that were
      # checked in less than +minimum_idle+ seconds ago, are unaffected.
      def flush(minimum_idle = @idle_timeout)
        return if minimum_idle.nil?

        idle_connections = synchronize do
          @connections.select do |conn|
            !conn.in_use? && conn.seconds_idle >= minimum_idle
          end.each do |conn|
            conn.lease

            @available.delete conn
            @connections.delete conn

            @connected.value = @connections.any?
          end
        end

        idle_connections.each do |conn|
          conn.disconnect!
        end
      end

      # Disconnect all currently idle connections. Connections currently checked
      # out are unaffected.
      def flush!
        reap
        flush(-1)
      end

      def num_waiting_in_queue # :nodoc:
        @available.num_waiting
      end
      private :num_waiting_in_queue

      # Return connection pool's usage statistic
      # Example:
      #
      #    ActiveRecord::Base.connection_pool.stat # => { size: 15, connections: 1, busy: 1, dead: 0, idle: 0, waiting: 0, checkout_timeout: 5 }
      def stat
        synchronize do
          {
            size: size,
            connections: @connections.size,
            busy: @connections.count { |c| c.in_use? && c.owner.alive? },
            dead: @connections.count { |c| c.in_use? && !c.owner.alive? },
            idle: @connections.count { |c| !c.in_use? },
            waiting: num_waiting_in_queue,
            checkout_timeout: checkout_timeout
          }
        end
      end

      # NOTE: active? and reset! are >= AR 2.3

      def reaper?; (@reaper ||= nil) && @reaper.frequency end
      def reaping?; reaper? && @reaper.running? end

      def validator?; (@validator ||= nil) && @validator.frequency end
      def validating?; validator? && @validator.running? end

      #@@logger = nil
      def logger; ::ActiveRecord::Base.logger end
      #def logger=(logger); @@logger = logger end

      private

      def bulk_make_new_connections(num_new_conns_needed)
        num_new_conns_needed.times do
          # try_to_checkout_new_connection will not exceed pool's @size limit
          if new_conn = try_to_checkout_new_connection
            # make the new_conn available to the starving threads stuck @available Queue
            checkin(new_conn)
          end
        end
      end

      # Acquire a connection by one of 1) immediately removing one
      # from the queue of available connections, 2) creating a new
      # connection if the pool is not at capacity, 3) waiting on the
      # queue for a connection to become available.
      #
      # @raise [ActiveRecord::ConnectionTimeoutError]
      # @raise [ActiveRecord::ConnectionNotEstablished]
      def acquire_connection(checkout_timeout)
        if conn = @available.poll || try_to_checkout_new_connection
          conn
        else
          reap unless @reaping
          @available.poll(checkout_timeout)
        end
      end

      #--
      # if owner_thread param is omitted, this must be called in synchronize block
      def remove_connection_from_thread_cache(conn, owner_thread = conn.owner)
        @thread_cached_conns.delete_pair(connection_cache_key(owner_thread), conn)
      end
      alias_method :release, :remove_connection_from_thread_cache

      # If the pool is not at a <tt>@size</tt> limit, establish new connection. Connecting
      # to the DB is done outside main synchronized section.
      #--
      # Implementation constraint: a newly established connection returned by this
      # method must be in the +.leased+ state.
      def try_to_checkout_new_connection
        # first in synchronized section check if establishing new conns is allowed
        # and increment @now_connecting, to prevent overstepping this pool's @size
        # constraint
        do_checkout = synchronize do
          if @threads_blocking_new_connections.zero? && (@connections.size + @now_connecting) < @size
            @now_connecting += 1
          end
        end
        if do_checkout
          begin
            # if successfully incremented @now_connecting establish new connection
            # outside of synchronized section
            conn = checkout_new_connection
          ensure
            synchronize do
              if conn
                adopt_connection(conn)
                # returned conn needs to be already leased
                conn.lease
              end
              @now_connecting -= 1
            end
          end
        end
      end

      def adopt_connection(conn)
        conn.pool = self
        @connections << conn
      end

      def checkout_new_connection
        raise ConnectionNotEstablished unless @automatic_reconnect
        conn = new_connection
        @connected.make_true
        conn
      end

      def checkout_and_verify(conn)
        _run_checkout_callbacks(conn)
        conn
      rescue => e
        remove conn
        conn.disconnect!
        raise e
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

    end

  end
end
