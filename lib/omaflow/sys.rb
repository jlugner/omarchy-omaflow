# frozen_string_literal: true

require 'open3'

module Omaflow
  module Sys
    module_function

    def which(command)
      ENV.fetch('PATH', '').split(':').map { File.join(it, command) }.find { File.executable?(it) }
    end

    def run(*argv, timeout: 30)
      system('timeout', '--kill-after=10', timeout.to_s, *argv, out: File::NULL, err: File::NULL)
    end

    CAPTURE_MAX_BYTES = 1_048_576

    def capture(*argv, timeout: 30, chdir: nil, max_bytes: CAPTURE_MAX_BYTES)
      options = { err: File::NULL }
      options[:chdir] = chdir if chdir
      Open3.popen2('timeout', '--kill-after=10', timeout.to_s, *argv, **options) do |stdin, stdout, waiter|
        stdin.close
        out = +''
        overflow = false
        while (chunk = stdout.read(65_536))
          out << chunk
          next if out.bytesize <= max_bytes

          overflow = true
          break
        end
        begin
          stdout.close
        rescue IOError
          nil
        end
        status = waiter.value
        [out.byteslice(0, max_bytes).to_s, status.success? && !overflow, status.exitstatus]
      end
    rescue SystemCallError, IOError
      ['', false, nil]
    end

    def detached(*argv) = Process.detach(Process.spawn('setsid', *argv, out: File::NULL, err: File::NULL))

    def process_command(pid)
      File.read("/proc/#{pid}/cmdline").split("\0").join(' ')
    rescue SystemCallError, IOError
      nil
    end

    def descendants(pid)
      children = Hash.new { |hash, key| hash[key] = [] }
      Dir.glob('/proc/[0-9]*/stat').each do |path|
        fields = File.read(path).rpartition(')').last.split
        children[fields[1].to_i] << File.basename(File.dirname(path)).to_i
      rescue SystemCallError, IOError
        next
      end
      found = []
      queue = [pid]
      until queue.empty?
        current = queue.shift
        children[current].each do |child|
          found << child
          queue << child
        end
      end
      found
    end

    def notify(*)
      tool = %w[omarchy-notification-send notify-send].find { which(it) }
      system(tool, *, out: File::NULL, err: File::NULL) if tool
    end

    def subst(haystack, needle, replacement) = haystack.gsub(needle) { replacement }

    def now_iso = Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z')
  end
end
