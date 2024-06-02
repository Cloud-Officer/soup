# frozen_string_literal: true

require 'active_support'
require 'active_support/core_ext'
require 'cocoapods-core' if RUBY_PLATFORM.match?(/darwin/i)
require 'semantic'

require_relative '../package'

module SOUP
  class CocoaPodsParser
    def parse(file, packages)
      lock_file = Pod::Lockfile.from_file(Pathname.new(file))
      main_file = File.read(file.gsub('.lock', '')).delete('/')
      source = Pod::Source.new("#{Dir.home}/.cocoapods/repos/trunk")

      _key, pods = lock_file&.pods_by_spec_repo&.first

      pods.each do |pod|
        version = Semantic::Version.new(lock_file&.version(pod)&.version)
        version.patch = 0 if version.patch != 0
        puts("Checking #{pod} #{version}...")

        begin
          package_details = source.specification(pod.delete('/').gsub('Only', ''), version).attributes_hash
        rescue Pod::StandardError
          next
        end

        package = Package.new(pod)
        package.file = file
        package.language = 'Swift'
        package.version = package_details['version']&.strip
        package.license = package_details['license']['type']&.strip
        package.description = package_details['description']&.split(/\n|\. /)&.first&.gsub(%r{((?:f|ht)tps?:/\S+)}, '<\1>')
        package.website = package_details['homepage']&.strip
        package.dependency = !main_file.include?(package.package)
        packages[package.package] = package
      end
    end
  end
end
