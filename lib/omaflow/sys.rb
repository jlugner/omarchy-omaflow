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

    def capture(*argv, timeout: 30, chdir: nil)
      options = { err: File::NULL }
      options[:chdir] = chdir if chdir
      out, status = Open3.capture2('timeout', '--kill-after=10', timeout.to_s, *argv, **options)
      [out, status.success?]
    rescue SystemCallError
      ['', false]
    end

    def detached(*argv) = Process.detach(Process.spawn('setsid', *argv, out: File::NULL, err: File::NULL))

    def notify(*)
      tool = %w[omarchy-notification-send notify-send].find { which(it) }
      system(tool, *, out: File::NULL, err: File::NULL) if tool
    end

    def subst(haystack, needle, replacement) = haystack.gsub(needle) { replacement }

    def now_iso = Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z')
  end
end
