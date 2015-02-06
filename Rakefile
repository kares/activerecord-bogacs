require 'bundler/gem_tasks'

require 'rake/testtask'
Rake::TestTask.new do |t|
  t.pattern = "test/**/*_test.rb"
end

task :default => :test

desc "Creates a (test) MySQL database"
task 'db:create:mysql' do
  fail "could not create database: mysql executable not found" unless mysql = _which('mysql')
  ENV['Rake'] = true.to_s; ENV['AR_ADAPTER'] ||= 'mysql'
  require File.expand_path('test/test_helper.rb', File.dirname(__FILE__))

  script = "DROP DATABASE IF EXISTS `#{AR_CONFIG[:database]}`;"
  script << "CREATE DATABASE `#{AR_CONFIG[:database]}` DEFAULT CHARACTER SET `utf8` COLLATE `utf8_general_ci`;"
  if AR_CONFIG[:username]
    script << "GRANT ALL PRIVILEGES ON `#{AR_CONFIG[:database]}`.* TO #{AR_CONFIG[:username]}@localhost;"
    script << "SET PASSWORD FOR #{AR_CONFIG[:username]}@localhost = PASSWORD('#{AR_CONFIG[:password]}');"
  end
  params = { '-u' => 'root' }
  if ENV['DATABASE_YML']; require 'yaml'
    password = YAML.load(File.new(ENV['DATABASE_YML']))["production"]["password"]
    params['--password'] = password
  end
  puts "Creating MySQL database: #{AR_CONFIG[:database]}"
  sh "cat #{_sql_script(script).path} | #{mysql} #{params.to_a.join(' ')}", :verbose => $VERBOSE
  # puts "... run tests with MySQL using: `AR_ADAPTER=mysql rake test `"
end

desc "Creates a (test) PostgreSQL database"
task 'db:create:postgresql' do
  fail 'could not create database: psql executable not found' unless psql = _which('psql')
  ENV['Rake'] = true.to_s; ENV['AR_ADAPTER'] ||= 'postgresql'
  require File.expand_path('test/test_helper.rb', File.dirname(__FILE__))

  script = "DROP DATABASE IF EXISTS #{AR_CONFIG[:database]};"
  if pg_user = AR_CONFIG[:username] || ENV['PGUSER'] || ENV_JAVA['user.name']
    script << "DROP USER IF EXISTS #{pg_user};"
    pg_password = AR_CONFIG[:password] || ENV['PGPASSWORD']
    script << "CREATE USER #{pg_user} CREATEDB SUPERUSER LOGIN PASSWORD '#{pg_password}';"
  end
  script << "CREATE DATABASE #{AR_CONFIG[:database]} OWNER #{pg_user || 'postgres'};"

  psql_params = "-U #{ENV['PSQL_USER'] || 'postgres'}"
  psql_params << " -h #{ENV['PGHOST']}" if ENV['PGHOST']
  psql_params << " -p #{ENV['PGPORT']}" if ENV['PGPORT']
  psql_params << " -q " unless $VERBOSE

  puts "Creating PostgreSQL database: #{AR_CONFIG[:database]}"
  sh "cat #{_sql_script(script).path} | #{psql} #{psql_params}", :verbose => $VERBOSE
  # puts "... run tests with PostgreSQL using: `AR_ADAPTER=postgresql rake test `"
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
        env_key = "#{tomcat_pool.upcase.sub('-', '_')}_VERSION" # 'TOMCAT_JDBC_VERSION'
        version = args[:version] || ENV[env_key] || version_default

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

  mchange_commons_jar = "mchange-commons-java-#{mchange_commons_version}.jar"

  task :download, :version do |_,args| # rake c3p0:download
    version = args[:version] || ENV['C3P0_VERSION'] || c3p0_version

    c3p0_jar = "c3p0-#{version}.jar"

    uri = "#{mchange_base_repo}/mchange-commons-java/#{mchange_commons_version}/#{mchange_commons_jar}"

    _download(uri, download_dir, mchange_commons_jar)

    uri = "#{mchange_base_repo}/c3p0/#{version}/#{c3p0_jar}"

    _download(uri, download_dir, c3p0_jar)
  end

  task :clear do
    Dir.glob( File.join(download_dir, '{c3p0,mchange-commons}*.jar') ).each { |jar| rm jar }
  end

end

namespace :hikari do

  hikari_base_repo = 'http://repo2.maven.org/maven2/com/zaxxer'
  slf4j_base_repo = 'http://repo2.maven.org/maven2/org/slf4j'
  javassist_base_repo = 'http://repo2.maven.org/maven2/org/javassist'
  download_dir = File.expand_path('test/jars', File.dirname(__FILE__))
  hikari_version = '1.4.0'
  slf4j_version = '1.7.10'
  javassist_version = '3.18.2-GA'

  slf4j_api_jar = "slf4j-api-#{slf4j_version}.jar"
  slf4j_simple_jar = "slf4j-simple-#{slf4j_version}.jar"
  javassist_jar = "javassist-#{javassist_version}.jar"

  task :download, :version do |_,args| # rake c3p0:download
    version = args[:version] || ENV['HIKARI_VERSION'] || hikari_version

    version = version.dup
    if version.sub!('-java6', '') # e.g. '2.3.2-java6'
      hikari_jar = "HikariCP-java6-#{version}.jar"
      uri = "#{hikari_base_repo}/HikariCP-java6/#{version}/#{hikari_jar}"
    else
      hikari_jar = "HikariCP-#{version}.jar"
      uri = "#{hikari_base_repo}/HikariCP/#{version}/#{hikari_jar}"
    end

    _download(uri, download_dir, hikari_jar)

    uri = "#{slf4j_base_repo}/slf4j-api/#{slf4j_version}/#{slf4j_api_jar}"
    _download(uri, download_dir, slf4j_api_jar)

    uri = "#{slf4j_base_repo}/slf4j-simple/#{slf4j_version}/#{slf4j_simple_jar}"
    _download(uri, download_dir, slf4j_simple_jar)

    uri = "#{javassist_base_repo}/javassist/#{javassist_version}/#{javassist_jar}"
    _download(uri, download_dir, javassist_jar)
  end

  task :clear do
    Dir.glob( File.join(download_dir, '{HikariCP,slf4j,javassist}*.jar') ).each { |jar| rm jar }
  end

end
