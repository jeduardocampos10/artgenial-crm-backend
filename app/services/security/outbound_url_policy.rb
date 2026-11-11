# frozen_string_literal: true

require 'ipaddr'
require 'resolv'
require 'uri'

# Validates and resolves outbound integration destinations before a connection.
# Callers must pin Net::HTTP#ipaddr to the returned address so DNS is not resolved
# again between validation and connect. Network egress rules remain mandatory.
class Security::OutboundUrlPolicy
  BLOCKED_NETWORKS = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
    172.16.0.0/12 192.0.0.0/24 192.168.0.0/16 198.18.0.0/15
    224.0.0.0/4 240.0.0.0/4 ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8
  ].map { |cidr| IPAddr.new(cidr) }.freeze

  Result = Data.define(:uri, :ip_address)

  def self.validate!(raw_url)
    uri = URI.parse(raw_url.to_s)
    unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.blank? && uri.fragment.blank?
      raise ArgumentError, 'outbound destination must be an HTTPS URL without credentials or fragment'
    end

    addresses = Resolv.getaddresses(uri.host).uniq
    raise ArgumentError, 'outbound destination could not be resolved' if addresses.empty?

    parsed_addresses = addresses.map { |address| IPAddr.new(address) }
    if parsed_addresses.any? { |address| blocked?(address) }
      raise ArgumentError, 'outbound destination resolves to a non-public address'
    end

    Result.new(uri, addresses.first)
  rescue URI::InvalidURIError, IPAddr::InvalidAddressError
    raise ArgumentError, 'invalid outbound destination'
  end

  def self.blocked?(address)
    candidates = [address]
    candidates << address.native if address.ipv4_mapped?
    candidates.any? { |candidate| BLOCKED_NETWORKS.any? { |network| network.include?(candidate) } }
  end
  private_class_method :blocked?
end
