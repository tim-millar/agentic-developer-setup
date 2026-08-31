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

        resolved = resolve_without_following_unsafe_symlinks(candidate)
        reject! if inside?(resolved, target)
        candidate
      rescue Errno::EACCES, Errno::ELOOP, Errno::EINVAL, Errno::ENOTDIR => e
        raise InvocationError, "output destination cannot be resolved: #{e.message}"
      end

      def reject!
        raise InvocationError, "output and report paths must be outside the assessed repository"
      end

      def inside?(path, root)
        path == root || path.to_s.start_with?("#{root}#{File::SEPARATOR}")
      end

      def resolve_without_following_unsafe_symlinks(path)
        pending = path.to_s.split(File::SEPARATOR).reject(&:empty?)
        resolved = Pathname.new(File::SEPARATOR)
        symlink_depth = 0

        until pending.empty?
          component = pending.shift
          next if component == "."
          if component == ".."
            resolved = resolved.parent
            next
          end

          candidate = resolved.join(component)
          stat = begin
            candidate.lstat
          rescue Errno::ENOENT
            # Missing regular path components are safe to append. Existing
            # symlinks have already been resolved without following them.
            resolved = resolved.join(component)
            next
          rescue Errno::ENOTDIR
            raise Errno::ENOTDIR
          end
          if stat.symlink?
            symlink_depth += 1
            raise Errno::ELOOP if symlink_depth > 40

            link = File.readlink(candidate.to_s)
            target = if link.start_with?(File::SEPARATOR)
                       Pathname.new(link).expand_path
                     else
                       candidate.parent.join(link).expand_path
                     end
            pending = target.to_s.split(File::SEPARATOR).reject(&:empty?) + pending
            resolved = Pathname.new(File::SEPARATOR)
          else
            resolved = candidate
          end
        end
        resolved.cleanpath
      end

      private_class_method :inside?
    end
  end
end
