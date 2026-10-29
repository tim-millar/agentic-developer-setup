#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "adoption_demo_support"
demo = AdoptionDemo.new
begin
  demo.update_inherited
ensure
  demo.close
end
