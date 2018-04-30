# ActiveRecord::Bogacs

ActiveRecord (all-year) pooling "alternatives" ... in a relaxed 'spa' fashion.

![Bogacs][0]

Bogács is a village in Borsod-Abaúj-Zemplén county, Hungary.

**NOTE: do not put this on production if you do not understand the consequences!**

## Install

add this line to your application's *Gemfile*:

    gem 'activerecord-bogacs', :require => 'active_record/bogacs'

... or install it yourself as:

    $ gem install activerecord-bogacs

## Setup

Bogacs' pools rely on a small monkey-patch that allows to change the AR pool.
The desired pool class needs to be set before `establish_connection` happens,
thus an initializer (under Rails) won't work, you might consider setting the 
pool class at the bottom of your *application.rb* e.g. :

```ruby
Bundler.require(*Rails.groups)

module MyApp
  class Application < Rails::Application
    # config.middleware.delete 'ActiveRecord::QueryCache'
  end
end

# sample AR-Bogacs setup using the "default" pool :
if Rails.env.production?
  pool_class = ActiveRecord::Bogacs::DefaultPool
  ActiveRecord::ConnectionAdapters::ConnectionHandler.connection_pool_class = pool_class
end
```

Alternatively, for `FalsePool`, there's a configuration convention (no need to path 
and set the connection_pool_class) :
```yaml
production:
  adapter: mysql2
  <% if $servlet_context %>
  jndi: java:comp/env/jdbc/mydb
  pool: false # use AR::Bogacs::FalsePool
  <% else %>
  port: <%= ENV['DATABASE_PORT'] || 3306 %>
  database: mydb
  # ...
  <% end %>
```

This works only as long as one doesn't set a custom connection handler, since 
*Bogacs* only sets up its custom `ActiveRecord::Base.default_connection_handler`.

Pools are expected to work with older ActiveRecord versions: 3.x as well as 4.x.

### [Default Pool][2]

Meant, primarily, as a back-port for users stuck with old Rails versions (< 4.0) 
on production, facing potential (pool related) concurrency bugs e.g. with highly 
concurrent loads under JRuby, although it also enhances some of the thread locking
issues present in 4.x's pool. 

Based on pool code from 4.x (which works much better than any previous version),
with a few minor tunings and extensions such as `pool_initial: 0.5` which allows
to specify how many connections to initialize in advance when the pool is created.

### [False Pool][3]

The false pool won't do any actual pooling, it is assumed that an underlying pool
is configured. Still, it does maintain a hash of AR connections mapped to threads.
Ignores pool related configuration such as `pool: 42` or `checkout_timeout: 2.5`.

**NOTE:** be sure to configure an underlying pool e.g. with Trinidad (using the
default Tomcat JDBC pool) :

```yaml
---
  http: # true
    port: 3000
    # ...
  extensions:
    mysql_dbpool:
      url: jdbc:mysql:///my_production
      username: root
      jndi: jdbc/MyDB
      initialSize: <%= ENV['POOL_INITIAL'] || 25 %> # connections created on start
      maxActive: <%= ENV['POOL_SIZE'] || 100 %> # default 100 (AR pool: size)
      maxIdle: <%= ENV['POOL_SIZE'] || 100 %> # max connections kept in the pool
      minIdle: <%= ENV['POOL_INITIAL'] || 50 %>
      # idle connections are checked periodically (if enabled) and connections
      # that been idle for longer than minEvictableIdleTimeMillis will be released
      minEvictableIdleTimeMillis: <%= 3 * 60 * 1000 %> # default 60s
      # AR checkout_timeout: 5
      maxWait: <%= (( ENV['POOL_TIMEOUT'] || 5.0 ).to_f * 1000).to_i %> # default 30s
```

[ActiveRecord-JDBC][5] adapter allows you to lookup connection from JNDI using the
following configuration :

```
production:
  adapter: mysql2
  jndi: java:/comp/env/jdbc/MyDB
```

**NOTE:** when using `FalsePool` there's nothing to configure (in *database.yml*)!

### Shareable Pool

This pool allows for a database connection to be "shared" among threads, this is
very **dangerous** normally. You will need to understand the underlying driver's
connection implementation (whether its thread-safe).

You'll need to manually declare blocks that run with a shared connection (**make
sure** only read operations happen within such blocks) similar to the built-in
`with_connection` e.g. :

```ruby
cache_fetch( [ 'user', user_id ] ) do
  ActiveRecord::Base.with_shared_connection { User.find(user_id) }
end
```

The pool "might" share connections among such blocks but only if it runs out of 
all connections (pool size is reached), until than it will always prefer checking 
out a connection just like `with_connection` does.

Tested with ActiveRecord-JDBC-Adapter using the official Postgres' driver (< 42).

## Copyright

Copyright (c) 2018 [Karol Bucek](http://kares.org).
See LICENSE (http://en.wikipedia.org/wiki/MIT_License) for details.

[0]: http://res.cloudinary.com/kares/image/upload/c_scale,h_600,w_800/v1406451696/bogacs.jpg
[1]: http://www.rubydoc.info/gems/activerecord-bogacs/
[2]: http://www.rubydoc.info/gems/activerecord-bogacs/ActiveRecord/Bogacs/DefaultPool
[3]: http://www.rubydoc.info/gems/activerecord-bogacs/ActiveRecord/Bogacs/FalsePool
[5]: https://github.com/jruby/activerecord-jdbc-adapter
