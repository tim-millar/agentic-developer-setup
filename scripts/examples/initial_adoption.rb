#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "adoption_demo_support"
demo = AdoptionDemo.new
begin
  demo.initial_adoption
ensure
  demo.close
end
