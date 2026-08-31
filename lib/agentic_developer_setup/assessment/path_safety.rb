# frozen_string_literal: true

require "pathname"

module AgenticDeveloperSetup
  module Assessment
    module PathSafety
      module_function

      def validate_output!(path, target_root)
        candidate = Pathname.new(path.to_s).expand_path
        target = Pathname.new(target_root).realpath
        reject! if inside?(candidate, target)

        existing = candidate
        until existing.exist?
          parent = existing.parent
          break if parent == existing

          existing = parent
        end
        resolved_parent = existing.realpath
        unresolved = candidate.to_s.delete_prefix(existing.to_s).sub(%r{\A/}, "")
        resolved = unresolved.empty? ? resolved_parent : resolved_parent.join(unresolved)
        reject! if inside?(resolved, target)
        candidate
      rescue Errno::EACCES, Errno::ENOENT => e
        raise InvocationError, "output destination cannot be resolved: #{e.message}"
      end

      def reject!
        raise InvocationError, "output and report paths must be outside the assessed repository"
      end

      def inside?(path, root)
        path == root || path.to_s.start_with?("#{root}#{File::SEPARATOR}")
      end
      private_class_method :inside?
    end
  end
end
