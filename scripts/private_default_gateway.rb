#!/usr/bin/env ruby
# frozen_string_literal: true

require "ipaddr"

route_path = ARGV.fetch(0, "/proc/net/route")
routes = File.foreach(route_path).drop(1).filter_map do |line|
  fields = line.split
  next unless fields.length >= 8
  next unless fields.fetch(1) == "00000000"
  next unless (fields.fetch(3).to_i(16) & 0x2) == 0x2

  fields
end

routes.sort_by { |fields| fields.fetch(6).to_i }.each do |fields|
  gateway_hex = fields.fetch(2)
  next unless gateway_hex.match?(/\A[0-9A-Fa-f]{8}\z/)

  gateway = gateway_hex.scan(/../).reverse.map { |octet| octet.to_i(16) }.join(".")
  address = IPAddr.new(gateway)
  next unless address.ipv4? && address.private?

  puts address
  exit 0
end

abort "no private IPv4 default-route gateway found in #{route_path}"
