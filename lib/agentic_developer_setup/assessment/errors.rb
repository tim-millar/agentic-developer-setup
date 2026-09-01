# frozen_string_literal: true

module AgenticDeveloperSetup
  module Assessment
    class Error < StandardError; end
    class InvocationError < Error; end
    class InternalError < Error; end
    class SchemaError < Error; end
  end
end
