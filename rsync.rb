#!/usr/bin/env ruby

require 'rainbow/ext/string'
require 'yaml'
require 'open3'
require 'socket'
require 'timeout'
require 'choice'


def port_open?(ip, port, timeout=1)
  Timeout::timeout(timeout) do
    begin
      TCPSocket.new(ip, port).close
      true
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError
      false
    end
  end
rescue Timeout::Error
  false
end

def next_color
  idx = 0
  colors = %i(red green yellow blue magenta cyan aqua).shuffle
  lambda do
    color = colors[idx]
    idx = (idx + 1) % colors.length
    return color
  end
end

def docker_ip(settings)
  `docker-machine ip #{settings['docker_machine_name'] || 'default'}`.chomp
end

def output(string, service_name, color)
  puts sprintf("%-10s| ".color(color), service_name) + string
end

def output_notice(notice, service_name, color)
  output(notice.color(color), service_name, color)
end

def run_command(command, service_name, color)
  Open3.popen2e(command) do |stdin, stdout_err, wait_thr|
    while (line = stdout_err.gets)
      if /error/ =~ line
        output_notice("Error detected - restarting", service_name, color)
        Process.kill("KILL", wait_thr.pid)
        throw :fail
      end
      output(line, service_name, color)
    end

    unless wait_thr.value.success?
      throw :fail
    end
  end
end

def wait_for(host, port, sleep=1)
  until port_open?(host, port) do
    sleep(sleep)
  end
end

def sync_service(settings, service, service_name, color)
  rsync_ssh_port = service["rsync_ssh_port"]

  while true
    # wait for the rsync server
    output_notice("Waiting for rsync server", service_name, color)
    wait_for(docker_ip(settings), rsync_ssh_port)
    # sync in it's thread
    sync_thread = Thread.new do
      do_sync_service(settings, service, service_name, color)
    end

    # use another thread to monitor the rsync server
    watchdog_thread = Thread.new do
      while port_open?(docker_ip(settings), rsync_ssh_port) && sync_thread.alive?  do
        sleep(1)
      end
      output_notice("Rsync server unreachable", service_name, color)
      Thread.exit
    end
    watchdog_thread.join
    Thread.kill(sync_thread) if sync_thread.alive?
  end
end

def do_sync_service(settings, service, service_name, color)
  key_path = settings['rsa_key_path']
  catch(:fail) do
    # setup
    rsync_ssh_port = service["rsync_ssh_port"]
    ssh_cmd = "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i #{key_path} -p #{rsync_ssh_port}"
    rsync_excludes = service["exclude"].reduce("") do |memo, value|
      exclude = "--exclude '#{value}'"
      memo.empty? ? exclude : memo + " " + exclude
    end
    fswatch_excludes = service["exclude"].reduce("") do |memo, value|
      exclude = "-e #{value}"
      memo.empty? ? exclude : memo + " " + exclude
    end

    rsync_options="-ravz --delete #{rsync_excludes}".chomp
    source = service["context"]

    # do initial sync
    output_notice("Initial sync started", service_name, color)
    run_command("rsync #{rsync_options} -e \"#{ssh_cmd}\" #{source}/ root@#{docker_ip(settings)}:#{service['volume_name']}", service_name, color)

    ## start python http server
    output_notice("Initial sync finished", service_name, color)
    run_command("#{ssh_cmd} root@#{docker_ip(settings)} \"python3 -m http.server 5001\" >/dev/null 2>&1 &", service_name, color)

    ## watch and do incremental sync
    output_notice("Incremental sync started", service_name, color)
    long_command = %Q(
        fswatch -0 -o #{fswatch_excludes} #{source} |
        xargs -0 -I {} rsync #{rsync_options} -e \"#{ssh_cmd}\" #{source}/ root@#{docker_ip(settings)}:#{service['volume_name']}
      )
    run_command(long_command, service_name, color)
  end
  Thread.exit
end


Choice.options do
  header ''
  header 'Specific options:'

  option :config_file do
    short '-f'
    long '--file=<path to yaml comfig file>'
    desc 'The path to the yaml config file'
    default 'rsync.yml'
  end
end

config_path = Choice['config_file']

# exit if the config file is missing
abort('[CRITICAL] Missing config file, aborting'.color(:red)) unless File.exists?(config_path)

# load yml config
config = YAML.load_file(config_path)


# sync each service in its own thread
services = config['services']
settings = config['settings'] || {}

abort('[CRITICAL] rsa_key_path not set, aborting'.color(:red)) unless settings['rsa_key_path']
threads = []
services.each_key do |service_name|
  context = services[service_name]['context']
  services[service_name]['context'] = File.absolute_path(File.join(File.dirname(config_path), context))
  threads << Thread.new do
    sync_service(settings, services[service_name], service_name, next_color.call)
  end
end
threads.each { |thread| thread.join }
