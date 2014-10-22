require 'bundler/gem_tasks'

require 'rake/testtask'
Rake::TestTask.new do |t|
  t.pattern = "test/**/*_test.rb"
end

task :default => :test

desc "Creates a (test) MySQL database"
task 'db:create:mysql' do
  fail "could not create database: mysql executable not found" unless mysql = _which('mysql')
  ENV['Rake'] = true; ENV['AR_ADAPTER'] ||= 'mysql'
  load File.expand_path('test/test_helper.rb', File.dirname(__FILE__))

  script = "DROP DATABASE IF EXISTS `#{AR_CONFIG[:database]}`;"
  script << "CREATE DATABASE `#{AR_CONFIG[:database]}` DEFAULT CHARACTER SET `utf8` COLLATE `utf8_general_ci`;"
  if AR_CONFIG[:username]
    script << "GRANT ALL PRIVILEGES ON `#{AR_CONFIG[:database]}`.* TO #{AR_CONFIG[:username]}@localhost;"
    script << "SET PASSWORD FOR #{AR_CONFIG[:username]}@localhost = PASSWORD('#{AR_CONFIG[:password]}');"
  end
  params = { '-u' => 'root' }
  if ENV['DATABASE_YML']
    require 'yaml'
    password = YAML.load(File.new(ENV['DATABASE_YML']))["production"]["password"]
    params['--password'] = password
  end
  puts "Creating MySQL database: #{AR_CONFIG[:database]}"
  sh "cat #{_sql_script(script).path} | #{mysql} #{params.to_a.join(' ')}", :verbose => $VERBOSE
  puts "... run tests with MySQL using: `rake test AR_ADAPTER=mysql`"
end

desc "Creates a (test) PostgreSQL database"
task 'db:create:postgresql' do
  fail 'could not create database: psql executable not found' unless psql = _which('psql')
  fail 'could not create database: missing "postgres" role' unless PostgresHelper.postgres_role?
  ENV['Rake'] = true; ENV['AR_ADAPTER'] ||= 'postgresql'
  load File.expand_path('test/test_helper.rb', File.dirname(__FILE__))

  script = "DROP DATABASE IF EXISTS #{AR_CONFIG[:database]};"
  if pg_user = AR_CONFIG[:username] || ENV['PGUSER'] || ENV_JAVA['user.name']
    script << "DROP USER IF EXISTS #{pg_user};"
    pg_password = AR_CONFIG[:password] || ENV['PGPASSWORD']
    script << "CREATE USER #{pg_user} CREATEDB SUPERUSER LOGIN PASSWORD '#{pg_password}';"
  end
  script << "CREATE DATABASE #{AR_CONFIG[:database]} OWNER #{pg_user || 'postgres'};"
  params = { '-U' => ENV['PSQL_USER'] || 'postgres' }; params['-q'] = nil unless $VERBOSE
  puts "Creating PostgreSQL database: #{AR_CONFIG[:database]}"
  sh "cat #{_sql_script(script).path} | #{psql} #{params.to_a.join(' ')}", :verbose => $VERBOSE
  puts "... run tests with PostgreSQL using: `rake test AR_ADAPTER=postgresql`"
end

def _sql_script(content, name = '_sql_script')
  require 'tempfile'
  script = Tempfile.new(name)
  script.puts content
  yield(script) if block_given?
  script.close
  at_exit { script.unlink }
  script
end

def _which(cmd)
  exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
  ( ENV['PATH'] || '' ).split(File::PATH_SEPARATOR).each do |path|
    exts.each do |ext|
      exe = File.join(path, "#{cmd}#{ext}")
      return exe if File.executable? exe
    end
  end
  nil
end

def _download(uri, download_dir, as_file_name)
  require 'open-uri'; require 'tmpdir'

  temp_dir = File.join(Dir.tmpdir, (Time.now.to_f * 1000).to_i.to_s)
  FileUtils.mkdir temp_dir

  Dir.chdir(temp_dir) do
    FileUtils.mkdir download_dir unless File.exist?(download_dir)
    puts "downloading #{uri}"
    file = open(uri)
    FileUtils.cp file.path, File.join(download_dir, as_file_name)
  end

  FileUtils.rm_r temp_dir
end

namespace :tomcat do

  tomcat_maven_repo = 'http://repo2.maven.org/maven2/org/apache/tomcat'
  download_dir = File.expand_path('test/jars', File.dirname(__FILE__))
  version_default = '7.0.54'

  [ 'tomcat-jdbc', 'tomcat-dbcp' ].each do |tomcat_pool|
    namespace tomcat_pool.sub('tomcat-', '') do # rake tomcat:dbcp:download

      tomcat_pool_jar = "#{tomcat_pool}.jar"

      task :download, :version do |_,args| # rake tomcat:jdbc:download[7.0.54]
        version = args[:version] || version_default

        uri = "#{tomcat_maven_repo}/#{tomcat_pool}/#{version}/#{tomcat_pool}-#{version}.jar"

        _download(uri, download_dir, tomcat_pool_jar)
      end

      task :check do
        jar_path = File.join(download_dir, tomcat_pool_jar)
        unless File.exist?(jar_path)
          Rake::Task["#{tomcat_pool.sub('-',':')}:download"].invoke
        end
      end

      task :clear do
        jar_path = File.join(download_dir, tomcat_pool_jar)
        rm jar_path if File.exist?(jar_path)
      end

    end
  end

  namespace 'jndi' do # contains a FS JNDI impl (for tests)

    catalina_jar = 'tomcat-catalina.jar'; juli_jar = 'tomcat-juli.jar'

    task :download, :version do |_,args|
      version = args[:version] || version_default

      catalina_uri = "#{tomcat_maven_repo}/tomcat-catalina/#{version}/tomcat-catalina-#{version}.jar"
      juli_uri = "#{tomcat_maven_repo}/tomcat-juli/#{version}/tomcat-juli-#{version}.jar"

      require 'open-uri'; require 'tmpdir'

      temp_dir = File.join(Dir.tmpdir, (Time.now.to_f * 1000).to_i.to_s)
      FileUtils.mkdir temp_dir

      downloads = Hash.new
      downloads[catalina_jar] = catalina_uri
      downloads[juli_jar] = juli_uri

      Dir.chdir(temp_dir) do
        FileUtils.mkdir download_dir unless File.exist?(download_dir)
        downloads.each do |jar, uri|
          puts "downloading #{uri}"
          file = open(uri)
          FileUtils.cp file.path, File.join(download_dir, jar)
        end
      end

      FileUtils.rm_r temp_dir
    end

    task :check do
      jar_path = File.join(download_dir, catalina_jar)
      unless File.exist?(jar_path)
        Rake::Task['tomcat:jndi:download'].invoke
      end
    end

    task :clear do
      jar_path = File.join(download_dir, catalina_jar)
      rm jar_path if File.exist?(jar_path)
      jar_path = File.join(download_dir, juli_jar)
      rm jar_path if File.exist?(jar_path)
    end

  end

end

namespace :c3p0 do

  mchange_base_repo = 'http://repo2.maven.org/maven2/com/mchange'
  download_dir = File.expand_path('test/jars', File.dirname(__FILE__))
  c3p0_version = '0.9.5-pre9'
  mchange_commons_version = '0.2.8'

  c3p0_jar = "c3p0-#{c3p0_version}.jar"
  mchange_commons_jar = "mchange-commons-java-#{mchange_commons_version}.jar"

  task :download, :version do |_,args| # rake c3p0:download
    # version = args[:version] || version_default

    uri = "#{mchange_base_repo}/mchange-commons-java/#{mchange_commons_version}/#{mchange_commons_jar}"

    _download(uri, download_dir, mchange_commons_jar)

    uri = "#{mchange_base_repo}/c3p0/#{c3p0_version}/#{c3p0_jar}"

    _download(uri, download_dir, c3p0_jar)
  end

  task :check do
    jar_path = File.join(download_dir, c3p0_jar)
    unless File.exist?(jar_path)
      Rake::Task["c3p0:download"].invoke
    end
  end

  task :clear do
    Dir.glob( File.join(download_dir, '{c3p0,mchange-commons}*.jar') ).each { |jar| rm jar }
  end

end