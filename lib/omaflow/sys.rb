# frozen_string_literal: true

require 'open3'

module Omaflow
  module Sys
    module_function

    def which(command)
      ENV.fetch('PATH', '').split(':').map { File.join(it, command) }.find { File.executable?(it) }
    end

    def run(*argv, timeout: 30)
      system('timeout', timeout.to_s, *argv, out: File::NULL, err: File::NULL)
    end

    def capture(*argv, timeout: 30)
      out, status = Open3.capture2('timeout', timeout.to_s, *argv, err: File::NULL)
      [out, status.success?]
    rescue SystemCallError
      ['', false]
    end

    def detached(*argv) = Process.detach(Process.spawn('setsid', *argv, out: File::NULL, err: File::NULL))

    def notify(*args)
      tool = %w[omarchy-notification-send notify-send].find { which(it) }
      system(tool, *args, out: File::NULL, err: File::NULL) if tool
    end

    def subst(haystack, needle, replacement) = haystack.gsub(needle) { replacement }

    def now_iso = Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z')
  end
end
