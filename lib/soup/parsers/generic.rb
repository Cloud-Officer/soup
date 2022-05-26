# frozen_string_literal: true

module SOUP
  class GenericParser
    def parse(parser, file, packages)
      raise('No parser specified!') if parser.nil?

      raise('No file specified!') if file.nil?

      raise(TypeError, 'file expects a string') unless file.is_a?(String)

      raise('No packages specified!') if packages.nil?

      raise(TypeError, 'packages expects a hash') unless packages.is_a?(Hash)

      parser.parse(file, packages)
    end
  end
end
