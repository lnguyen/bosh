module Bosh::Director::DeploymentPlan
  class DatabaseIpRepo
    include Bosh::Director::IpUtil
    class IpFoundInDatabaseAndCanBeRetried < StandardError; end
    class NoMoreIPsAvailableAndStopRetrying < StandardError; end

    def initialize(logger)
      @logger = Bosh::Director::TaggedLogger.new(logger, 'network-configuration')
    end

    def delete(ip, network_name)
      cidr_ip = CIDRIP.new(ip)

      ip_address = Bosh::Director::Models::IpAddress.first(
        address: cidr_ip.to_i,
        network_name: network_name,
      )

      if ip_address
        @logger.debug("Releasing ip '#{cidr_ip}'")
        ip_address.destroy
      else
        @logger.debug("Skipping releasing ip '#{cidr_ip}' for #{network_name}: not reserved")
      end
    end

    def add(reservation)
      cidr_ip = CIDRIP.new(reservation.ip)

      reservation_type = reservation.network.ip_type(cidr_ip)

      reserve_with_instance_validation(
        reservation.instance,
        cidr_ip,
        reservation,
        reservation_type.eql?(:static)
      )

      reservation.resolve_type(reservation_type)
      reservation.mark_reserved
      @logger.debug("Reserved ip '#{cidr_ip}' for #{reservation.network.name} as #{reservation_type}")
    end

    def allocate_dynamic_ip(reservation, subnet)
      begin
        ip_address = try_to_allocate_dynamic_ip(reservation, subnet)
      rescue NoMoreIPsAvailableAndStopRetrying
        @logger.debug('Failed to allocate dynamic ip: no more available')
        return nil
      rescue IpFoundInDatabaseAndCanBeRetried
        @logger.debug('Retrying to allocate dynamic ip: probably a race condition with another deployment')
        # IP can be taken by other deployment that runs in parallel
        # retry until succeeds or out of range
        retry
      end

      @logger.debug("Allocated dynamic IP '#{ip_address.ip}' for #{reservation.network.name}")
      ip_address.to_i
    end

    private

    def try_to_allocate_dynamic_ip(reservation, subnet)
      addresses_in_use = Set.new(network_addresses(reservation.network.name))
      first_range_address = subnet.range.first(Objectify: true).to_i - 1
      addresses_we_cant_allocate = addresses_in_use
      addresses_we_cant_allocate << first_range_address

      addresses_we_cant_allocate.merge(subnet.restricted_ips.to_a) unless subnet.restricted_ips.empty?
      addresses_we_cant_allocate.merge(subnet.static_ips.to_a) unless subnet.static_ips.empty?
      # find first in-use address whose subsequent address is not in use
      # the subsequent address must be free
      addr = addresses_we_cant_allocate
               .to_a
               .reject {|a| a < first_range_address }
               .sort
               .find { |a| !addresses_we_cant_allocate.include?(a+1) }
      ip_address = NetAddr::CIDRv4.new(addr+1)

      unless subnet.range == ip_address || subnet.range.contains?(ip_address)
        raise NoMoreIPsAvailableAndStopRetrying
      end

      save_ip(ip_address, reservation, false)

      ip_address
    end

    def network_addresses(network_name)
      Bosh::Director::Models::IpAddress.select(:address)
        .where(network_name: network_name).all.map { |a| a.address }
    end

    def reserve_with_instance_validation(instance, ip, reservation, is_static)
      # try to save IP first before validating it's instance to prevent race conditions
      save_ip(ip, reservation, is_static)
    rescue IpFoundInDatabaseAndCanBeRetried
      ip_address = Bosh::Director::Models::IpAddress.first(
        address: ip.to_i,
        network_name: reservation.network.name,
      )

      retry unless ip_address

      validate_instance_and_update_reservation_type(instance, ip, ip_address, is_static)
    end

    def validate_instance_and_update_reservation_type(instance, ip, ip_address, is_static)
      reserved_instance = ip_address.instance
      if reserved_instance == instance.model
        if ip_address.static != is_static
          reservation_type = is_static ? 'static' : 'dynamic'
          @logger.debug("Switching reservation type of IP: '#{ip}' to #{reservation_type}")
          ip_address.update(static: is_static)
        end

        return ip_address
      else
        raise Bosh::Director::NetworkReservationAlreadyInUse,
          "Failed to reserve IP '#{ip}' for instance '#{instance}': " +
            "already reserved by instance '#{reserved_instance.job}/#{reserved_instance.index}' " +
            "from deployment '#{reserved_instance.deployment.name}'"
      end
    end

    def save_ip(ip, reservation, is_static)
      Bosh::Director::Models::IpAddress.new(
        address: ip.to_i,
        network_name: reservation.network.name,
        instance: reservation.instance.model,
        task_id: Bosh::Director::Config.current_job.task_id,
        static: is_static
      ).save
    rescue Sequel::ValidationFailed, Sequel::DatabaseError => e
      error_message = e.message.downcase
      if error_message.include?('unique') || error_message.include?('duplicate')
        raise IpFoundInDatabaseAndCanBeRetried
      else
        raise e
      end
    end
  end
end