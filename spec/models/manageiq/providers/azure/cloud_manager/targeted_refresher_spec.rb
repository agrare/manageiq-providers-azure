require 'azure-armrest'

describe ManageIQ::Providers::Azure::CloudManager::Refresher do
  ALL_GRAPH_REFRESH_SETTINGS = [
    {
      :inventory_object_refresh => true,
      :inventory_collections    => {
        :saver_strategy => :default,
      },
    }
  ].freeze

  ALL_GRAPH_REFRESH_SETTINGS.each do |refresh_settings|
    context "with settings #{refresh_settings}" do
      before(:each) do
        @refresh_settings = refresh_settings.merge(:allow_targeted_refresh => true)

        stub_settings_merge(
          :ems_refresh => {
            :azure         => @refresh_settings,
            :azure_network => @refresh_settings,
          }
        )
      end

      before do
        _guid, _server, zone = EvmSpecHelper.create_guid_miq_server_zone

        @ems = FactoryGirl.create(:ems_azure_with_vcr_authentication, :zone => zone, :provider_region => 'eastus')

        @resource_group    = 'miq-azure-test1'
        @managed_vm        = 'miqazure-linux-managed'
        @device_name       = 'miq-test-rhel1' # Make sure this is running if generating a new cassette.
        @vm_powered_off    = 'miqazure-centos1' # Make sure this is powered off if generating a new cassette.
        @ip_address        = '52.224.165.15'  # This will change if you had to restart the @device_name.
        @mismatch_ip       = '52.168.33.118'  # This will change if you had to restart the 'miqmismatch1' VM.
        @managed_os_disk   = "miqazure-linux-managed_OsDisk_1_7b2bdf790a7d4379ace2846d307730cd"
        @managed_data_disk = "miqazure-linux-managed-data-disk"
        @template          = nil
        @avail_zone        = nil

        @resource_group_managed_vm = "miq-azure-test4"
      end

      after do
        ::Azure::Armrest::Configuration.clear_caches
      end

      it ".ems_type" do
        expect(described_class.ems_type).to eq(:azure)
      end

      it "will refresh powered on VM" do
        vm_resource_id = "#{@ems.subscription}\\#{@resource_group}\\microsoft.compute/virtualmachines\\#{@device_name}"

        vm_target = ManagerRefresh::Target.new(:manager     => @ems,
                                               :association => :vms,
                                               :manager_ref => {:ems_ref => vm_resource_id})

        2.times do # Run twice to verify that a second run with existing data does not change anything
          refresh_with_cassette([vm_target], "_targeted/powered_on_vm_refresh")

          assert_specific_az
          assert_specific_cloud_network
          assert_specific_flavor
          assert_specific_disk
          assert_specific_security_group
          assert_specific_vm_powered_on

          assert_counts(
            :availability_zone     => 1,
            :cloud_network         => 1,
            :cloud_subnet          => 1,
            :disk                  => 1,
            :ext_management_system => 2,
            :flavor                => 1,
            :floating_ip           => 1,
            :hardware              => 1,
            :miq_queue             => 2,
            :network               => 2,
            :network_port          => 1,
            :operating_system      => 1,
            :resource_group        => 1,
            :security_group        => 1,
            :vm                    => 1,
            :vm_or_template        => 1
          )
        end
      end

      it "will refresh powered off VM" do
        vm_resource_id = "#{@ems.subscription}\\#{@resource_group}\\microsoft.compute/virtualmachines\\#{@vm_powered_off}"

        vm_target = ManagerRefresh::Target.new(:manager     => @ems,
                                               :association => :vms,
                                               :manager_ref => {:ems_ref => vm_resource_id})

        2.times do # Run twice to verify that a second run with existing data does not change anything
          refresh_with_cassette([vm_target], "_targeted/powered_off_vm_refresh")

          assert_specific_az
          assert_specific_flavor
          assert_specific_vm_powered_off

          assert_counts(
            :availability_zone     => 1,
            :cloud_network         => 1,
            :cloud_subnet          => 1,
            :disk                  => 1,
            :ext_management_system => 2,
            :flavor                => 1,
            :floating_ip           => 1,
            :hardware              => 1,
            :miq_queue             => 2,
            :network               => 2,
            :network_port          => 1,
            :operating_system      => 1,
            :resource_group        => 1,
            :security_group        => 1,
            :vm                    => 1,
            :vm_or_template        => 1
          )
        end
      end

      it "will refresh VM with managed disk" do
        vm_resource_id = "#{@ems.subscription}\\#{@resource_group_managed_vm}\\microsoft.compute/virtualmachines\\#{@managed_vm}"

        vm_target = ManagerRefresh::Target.new(:manager     => @ems,
                                               :association => :vms,
                                               :manager_ref => {:ems_ref => vm_resource_id})

        2.times do # Run twice to verify that a second run with existing data does not change anything
          refresh_with_cassette([vm_target], "_targeted/vm_with_managed_disk_refresh")

          assert_specific_az
          assert_specific_flavor
          assert_specific_vm_with_managed_disks
          assert_specific_managed_disk

          assert_counts(
            :availability_zone     => 1,
            :cloud_network         => 1,
            :cloud_subnet          => 1,
            :disk                  => 2,
            :ext_management_system => 2,
            :flavor                => 1,
            :floating_ip           => 1,
            :hardware              => 1,
            :miq_queue             => 2,
            :network               => 2,
            :network_port          => 1,
            :operating_system      => 1,
            :resource_group        => 1,
            :security_group        => 1,
            :vm                    => 1,
            :vm_or_template        => 1
          )
        end
      end

      it "will refresh orchestration stack" do
        stack_resource_id = "/subscriptions/2586c64b-38b4-4527-a140-012d49dfc02c/resourceGroups/miq-azure-test1/providers/Microsoft.Resources/deployments/spec-deployment-dont-delete"

        stack_target = ManagerRefresh::Target.new(:manager     => @ems,
                                                  :association => :orchestration_stacks,
                                                  :manager_ref => {:ems_ref => stack_resource_id})

        2.times do # Run twice to verify that a second run with existing data does not change anything
          refresh_with_cassette([stack_target], "_targeted/orchestration_stack_refresh")

          assert_stack_and_vm_targeted_refresh
        end
      end

      it "will refresh orchestration stack followed by Vm refresh" do
        stack_resource_id = "/subscriptions/2586c64b-38b4-4527-a140-012d49dfc02c/resourceGroups/miq-azure-test1/providers/Microsoft.Resources/deployments/spec-deployment-dont-delete"

        stack_target = ManagerRefresh::Target.new(:manager     => @ems,
                                                  :association => :orchestration_stacks,
                                                  :manager_ref => {:ems_ref => stack_resource_id})

        vm_resource_id = "2586c64b-38b4-4527-a140-012d49dfc02c\\miq-azure-test1\\microsoft.compute/virtualmachines\\spec0deply1vm0"
        vm_target = ManagerRefresh::Target.new(:manager     => @ems,
                                               :association => :vms,
                                               :manager_ref => {:ems_ref => vm_resource_id})

        2.times do # Run twice to verify that a second run with existing data does not change anything
          refresh_with_cassette([stack_target], "_targeted/orchestration_stack_refresh")

          assert_stack_and_vm_targeted_refresh

          refresh_with_cassette([vm_target], "_targeted/orchestration_stack_vm_refresh")
          assert_stack_and_vm_targeted_refresh
        end
      end

      it "will refresh orchestration stack with vms" do
        stack_resource_id = "/subscriptions/2586c64b-38b4-4527-a140-012d49dfc02c/resourceGroups/miq-azure-test1/providers/Microsoft.Resources/deployments/spec-deployment-dont-delete"

        stack_target = ManagerRefresh::Target.new(:manager     => @ems,
                                                  :association => :orchestration_stacks,
                                                  :manager_ref => {:ems_ref => stack_resource_id})

        vm_resource_id1 = "2586c64b-38b4-4527-a140-012d49dfc02c\\miq-azure-test1\\microsoft.compute/virtualmachines\\spec0deply1vm0"
        vm_target1      = ManagerRefresh::Target.new(:manager     => @ems,
                                                     :association => :vms,
                                                     :manager_ref => {:ems_ref => vm_resource_id1})

        vm_resource_id2 = "2586c64b-38b4-4527-a140-012d49dfc02c\\miq-azure-test1\\microsoft.compute/virtualmachines\\spec0deply1vm1"
        vm_target2      = ManagerRefresh::Target.new(:manager     => @ems,
                                                     :association => :vms,
                                                     :manager_ref => {:ems_ref => vm_resource_id2})

        2.times do # Run twice to verify that a second run with existing data does not change anything
          refresh_with_cassette([stack_target, vm_target1, vm_target2], "_targeted/orchestration_stack_refresh")

          assert_stack_and_vm_targeted_refresh
        end
      end

      it "will refresh orchestration stack followed by LoadBalancer refresh" do
        stack_resource_id = "/subscriptions/2586c64b-38b4-4527-a140-012d49dfc02c/resourceGroups/miq-azure-test1/providers/Microsoft.Resources/deployments/spec-deployment-dont-delete"

        stack_target = ManagerRefresh::Target.new(:manager     => @ems,
                                                  :association => :orchestration_stacks,
                                                  :manager_ref => {:ems_ref => stack_resource_id})

        lb_resource_id = "/subscriptions/2586c64b-38b4-4527-a140-012d49dfc02c/resourceGroups/miq-azure-test1/providers/Microsoft.Network/loadBalancers/spec0deply1lb"
        lb_target = ManagerRefresh::Target.new(:manager     => @ems,
                                               :association => :load_balancers,
                                               :manager_ref => {:ems_ref => lb_resource_id})

        2.times do # Run twice to verify that a second run with existing data does not change anything
          refresh_with_cassette([stack_target], "_targeted/orchestration_stack_refresh")

          assert_stack_and_vm_targeted_refresh

          refresh_with_cassette([lb_target], "_targeted/orchestration_stack_lb_refresh")
          assert_stack_and_vm_targeted_refresh
        end
      end

      it "will refresh LoadBalancer created by stack" do
        lb_resource_id = "/subscriptions/2586c64b-38b4-4527-a140-012d49dfc02c/resourceGroups/miq-azure-test1/providers/Microsoft.Network/loadBalancers/spec0deply1lb"
        lb_target = ManagerRefresh::Target.new(:manager     => @ems,
                                               :association => :load_balancers,
                                               :manager_ref => {:ems_ref => lb_resource_id})

        2.times do # Run twice to verify that a second run with existing data does not change anything
          refresh_with_cassette([lb_target], "_targeted/lb_created_by_stack_refresh")

          assert_counts(
            :ext_management_system => 2,
            :floating_ip           => 1,
            :load_balancer         => 1,
            :miq_queue             => 1,
            :network_port          => 1,
          )
        end
      end

      it "will refresh LoadBalancer" do
        lb_resource_id = "/subscriptions/#{@ems.subscription}/"\
                          "resourceGroups/miq-azure-test1/providers/Microsoft.Network/loadBalancers/rspec-lb1"
        lb_target = ManagerRefresh::Target.new(:manager     => @ems,
                                               :association => :load_balancers,
                                               :manager_ref => {:ems_ref => lb_resource_id})

        2.times do # Run twice to verify that a second run with existing data does not change anything
          refresh_with_cassette([lb_target], "_targeted/lb_refresh")

          assert_counts(
            :ext_management_system => 2,
            :floating_ip           => 1,
            :load_balancer         => 1,
            :miq_queue             => 1,
            :network_port          => 1
          )
        end
      end

      it "will refresh LoadBalancer with Vms refreshed before" do
        # Refresh Vms first
        2.times do # Run twice to verify that a second run with existing data does not change anything
          # Refresh Vms
          refresh_with_cassette(lbs_vms_targets, "_targeted/lb_vms_refresh")

          assert_counts(
            :availability_zone     => 1,
            :cloud_network         => 1,
            :cloud_subnet          => 1,
            :disk                  => 2,
            :ext_management_system => 2,
            :flavor                => 2,
            :floating_ip           => 2,
            :hardware              => 2,
            :miq_queue             => 3,
            :network               => 4,
            :network_port          => 2,
            :operating_system      => 2,
            :resource_group        => 1,
            :security_group        => 2,
            :vm                    => 2,
            :vm_or_template        => 2
          )
        end

        # Refresh LBs, those have to connect to the Vms
        2.times do # Run twice to verify that a second run with existing data does not change anything
          refresh_with_cassette(lbs_targets, "_targeted/lbs_refresh")

          assert_lbs_with_vms
        end
      end

      it "will refresh LoadBalancer with Vms" do
        2.times do # Run twice to verify that a second run with existing data does not change anything
          refresh_with_cassette(lbs_targets + lbs_vms_targets, "_targeted/lb_with_vms_refresh")

          assert_lbs_with_vms
        end
      end

      it "will refresh Template" do
        template_resource_id = "https://miqazuretest14047.blob.core.windows.net/system/"\
                               "Microsoft.Compute/Images/miq-test-container/"\
                               "test-win2k12-img-osDisk.e17a95b0-f4fb-4196-93c5-0c8be7d5c536.vhd"

        template_target = ManagerRefresh::Target.new(:manager     => @ems,
                                                     :association => :miq_templates,
                                                     :manager_ref => {:ems_ref => template_resource_id})

        2.times do # Run twice to verify that a second run with existing data does not change anything
          refresh_with_cassette([template_target], "_targeted/template_refresh")

          assert_specific_template
        end
      end

      def lbs_targets
        lb_resource_id1 = "/subscriptions/#{@ems.subscription}/"\
                          "resourceGroups/miq-azure-test1/providers/Microsoft.Network/loadBalancers/rspec-lb1"
        lb_target1      = ManagerRefresh::Target.new(:manager     => @ems,
                                                     :association => :load_balancers,
                                                     :manager_ref => {:ems_ref => lb_resource_id1})

        lb_resource_id2 = "/subscriptions/#{@ems.subscription}/"\
                          "resourceGroups/miq-azure-test1/providers/Microsoft.Network/loadBalancers/rspec-lb2"
        lb_target2      = ManagerRefresh::Target.new(:manager     => @ems,
                                                     :association => :load_balancers,
                                                     :manager_ref => {:ems_ref => lb_resource_id2})
        [lb_target1, lb_target2]
      end

      def lbs_vms_targets
        vm_resource_id1 = "2586c64b-38b4-4527-a140-012d49dfc02c\\miq-azure-test1\\microsoft.compute/virtualmachines\\rspec-lb-a"
        vm_target1      = ManagerRefresh::Target.new(:manager     => @ems,
                                                     :association => :vms,
                                                     :manager_ref => {:ems_ref => vm_resource_id1})

        vm_resource_id2 = "2586c64b-38b4-4527-a140-012d49dfc02c\\miq-azure-test1\\microsoft.compute/virtualmachines\\rspec-lb-b"
        vm_target2      = ManagerRefresh::Target.new(:manager     => @ems,
                                                     :association => :vms,
                                                     :manager_ref => {:ems_ref => vm_resource_id2})
        [vm_target1, vm_target2]
      end

      def assert_lbs_with_vms
        assert_specific_load_balancers
        assert_specific_load_balancer_networking
        assert_specific_load_balancer_listeners
        assert_specific_load_balancer_health_checks

        assert_counts(
          :availability_zone     => 1,
          :cloud_network         => 1,
          :cloud_subnet          => 1,
          :disk                  => 2,
          :ext_management_system => 2,
          :flavor                => 2,
          :floating_ip           => 4,
          :hardware              => 2,
          :load_balancer         => 2,
          :miq_queue             => 3,
          :network               => 4,
          :network_port          => 4,
          :operating_system      => 2,
          :resource_group        => 1,
          :security_group        => 2,
          :vm                    => 2,
          :vm_or_template        => 2
        )
      end

      def assert_stack_and_vm_targeted_refresh
        assert_specific_orchestration_template
        assert_specific_orchestration_stack

        assert_counts(
          :availability_zone             => 1,
          :cloud_network                 => 1,
          :cloud_subnet                  => 1,
          :disk                          => 2,
          :ext_management_system         => 2,
          :flavor                        => 1,
          :floating_ip                   => 1,
          :hardware                      => 2,
          :load_balancer                 => 1,
          :miq_queue                     => 3,
          :network                       => 2,
          :network_port                  => 3,
          :operating_system              => 2,
          :orchestration_stack           => 2,
          :orchestration_stack_output    => 1,
          :orchestration_stack_parameter => 29,
          :orchestration_stack_resource  => 10,
          :orchestration_template        => 2,
          :resource_group                => 1,
          :vm                            => 2,
          :vm_or_template                => 2
        )
      end

      def refresh_with_cassette(targets, suffix)
        @ems.reload

        name = described_class.name.underscore
        # We need different VCR for GraphRefresh
        name += suffix

        # Must decode compressed response for subscription id.
        VCR.use_cassette(name, :allow_unused_http_interactions => true, :decode_compressed_response => true) do
          EmsRefresh.refresh(targets)
        end

        @ems.reload
      end

      def setup_ems_and_cassette(refresh_settings)
        @ems.reload

        name = described_class.name.underscore
        # We need different VCR for GraphRefresh
        name += '_inventory_object' if refresh_settings[:inventory_object_refresh]

        # Must decode compressed response for subscription id.
        VCR.use_cassette(name, :allow_unused_http_interactions => true, :decode_compressed_response => true) do
          EmsRefresh.refresh(@ems)
          EmsRefresh.refresh(@ems.network_manager)
        end

        @ems.reload
      end

      def expected_table_counts
        {
          :ext_management_system         => 2,
          :flavor                        => 156,
          :availability_zone             => 1,
          :vm_or_template                => 14,
          :vm                            => 13,
          :miq_template                  => 1,
          :disk                          => 14,
          :guest_device                  => 0,
          :hardware                      => 14,
          :network                       => 23,
          :operating_system              => 13,
          :relationship                  => 0,
          :miq_queue                     => 15,
          :orchestration_template        => 21,
          :orchestration_stack           => 23,
          :orchestration_stack_parameter => 233,
          :orchestration_stack_output    => 11,
          :orchestration_stack_resource  => 84,
          :security_group                => 13,
          :network_port                  => 16,
          :cloud_network                 => 6,
          :floating_ip                   => 13,
          :network_router                => 0,
          :cloud_subnet                  => 6,
          :resource_group                => 4,
          :load_balancer                 => 3,
        }
      end

      def assert_counts(counts)
        assert_table_counts(base_expected_table_counts.merge(counts))
      end

      def base_expected_table_counts
        {
          :ext_management_system         => 0,
          :flavor                        => 0,
          :availability_zone             => 0,
          :vm_or_template                => 0,
          :vm                            => 0,
          :miq_template                  => 0,
          :disk                          => 0,
          :guest_device                  => 0,
          :hardware                      => 0,
          :network                       => 0,
          :operating_system              => 0,
          :relationship                  => 0,
          :miq_queue                     => 0,
          :orchestration_template        => 0,
          :orchestration_stack           => 0,
          :orchestration_stack_parameter => 0,
          :orchestration_stack_output    => 0,
          :orchestration_stack_resource  => 0,
          :security_group                => 0,
          :network_port                  => 0,
          :cloud_network                 => 0,
          :floating_ip                   => 0,
          :network_router                => 0,
          :cloud_subnet                  => 0,
          :resource_group                => 0,
          :load_balancer                 => 0,
        }
      end

      def actual_table_counts
        {
          :ext_management_system         => ExtManagementSystem.count,
          :flavor                        => Flavor.count,
          :availability_zone             => AvailabilityZone.count,
          :vm_or_template                => VmOrTemplate.count,
          :vm                            => Vm.count,
          :miq_template                  => MiqTemplate.count,
          :disk                          => Disk.count,
          :guest_device                  => GuestDevice.count,
          :hardware                      => Hardware.count,
          :network                       => Network.count,
          :operating_system              => OperatingSystem.count,
          :relationship                  => Relationship.count,
          :miq_queue                     => MiqQueue.count,
          :orchestration_template        => OrchestrationTemplate.count,
          :orchestration_stack           => OrchestrationStack.count,
          :orchestration_stack_parameter => OrchestrationStackParameter.count,
          :orchestration_stack_output    => OrchestrationStackOutput.count,
          :orchestration_stack_resource  => OrchestrationStackResource.count,
          :security_group                => SecurityGroup.count,
          :network_port                  => NetworkPort.count,
          :cloud_network                 => CloudNetwork.count,
          :floating_ip                   => FloatingIp.count,
          :network_router                => NetworkRouter.count,
          :cloud_subnet                  => CloudSubnet.count,
          :resource_group                => ResourceGroup.count,
          :load_balancer                 => LoadBalancer.count,
        }
      end

      def assert_table_counts(passed_counts = nil)
        expect(actual_table_counts).to eq (passed_counts || expected_table_counts)
      end

      def assert_ems
        expect(@ems.flavors.size).to eql(expected_table_counts[:flavor])
        expect(@ems.availability_zones.size).to eql(expected_table_counts[:availability_zone])
        expect(@ems.vms_and_templates.size).to eql(expected_table_counts[:vm_or_template])
        expect(@ems.security_groups.size).to eql(expected_table_counts[:security_group])
        expect(@ems.network_ports.size).to eql(expected_table_counts[:network_port])
        expect(@ems.cloud_networks.size).to eql(expected_table_counts[:cloud_network])
        expect(@ems.floating_ips.size).to eql(expected_table_counts[:floating_ip])
        expect(@ems.network_routers.size).to eql(expected_table_counts[:network_router])
        expect(@ems.cloud_subnets.size).to eql(expected_table_counts[:cloud_subnet])
        expect(@ems.miq_templates.size).to eq(expected_table_counts[:miq_template])

        expect(@ems.orchestration_stacks.size).to eql(expected_table_counts[:orchestration_stack])
        expect(@ems.direct_orchestration_stacks.size).to eql(22)
      end

      def assert_specific_load_balancers
        lb_ems_ref      = "/subscriptions/#{@ems.subscription}/"\
                          "resourceGroups/miq-azure-test1/providers/Microsoft.Network/loadBalancers/rspec-lb1"

        lb_pool_ems_ref = "/subscriptions/#{@ems.subscription}/"\
                          "resourceGroups/miq-azure-test1/providers/Microsoft.Network/loadBalancers/"\
                          "rspec-lb1/backendAddressPools/rspec-lb-pool"

        @lb = ManageIQ::Providers::Azure::NetworkManager::LoadBalancer.where(
          :name    => "rspec-lb1").first
        @lb_no_members = ManageIQ::Providers::Azure::NetworkManager::LoadBalancer.where(
          :name    => "rspec-lb2").first
        @pool          = ManageIQ::Providers::Azure::NetworkManager::LoadBalancerPool.where(
          :ems_ref => lb_pool_ems_ref).first

        expect(@lb).to have_attributes(
                         "ems_ref"         => lb_ems_ref,
                         "name"            => "rspec-lb1",
                         "description"     => nil,
                         "cloud_tenant_id" => nil,
                         "type"            => "ManageIQ::Providers::Azure::NetworkManager::LoadBalancer")

        expect(@lb.ext_management_system).to eq(@ems.network_manager)
        expect(@lb.vms.count).to eq 2
        expect(@lb.load_balancer_pools.first).to eq(@pool)
        expect(@lb.load_balancer_pool_members.count).to eq 2
        expect(@lb.load_balancer_pool_members.first.ext_management_system).to eq @ems.network_manager
        expect(@lb.vms.first.ext_management_system).to eq @ems
        expect(@lb.vms.collect(&:name).sort).to match_array ["rspec-lb-a", "rspec-lb-b"]
        expect(@lb_no_members.load_balancer_pool_members.count).to eq 0
      end

      def assert_specific_load_balancer_networking
        floating_ip      = FloatingIp.where(:address => "40.71.82.83").first

        expect(@lb).to eq floating_ip.network_port.device
      end

      def assert_specific_load_balancer_listeners
        lb_listener_ems_ref      = "/subscriptions/#{@ems.subscription}/resourceGroups/"\
                                   "miq-azure-test1/providers/Microsoft.Network/loadBalancers/rspec-lb1/"\
                                   "loadBalancingRules/rspec-lb1-rule"

        lb_pool_member_1_ems_ref = "/subscriptions/#{@ems.subscription}/resourceGroups/"\
                                   "miq-azure-test1/providers/Microsoft.Network/networkInterfaces/rspec-lb-a670/"\
                                   "ipConfigurations/ipconfig1"

        lb_pool_member_2_ems_ref = "/subscriptions/#{@ems.subscription}/resourceGroups/"\
                                   "miq-azure-test1/providers/Microsoft.Network/networkInterfaces/rspec-lb-b843/"\
                                   "ipConfigurations/ipconfig1"

        @listener = ManageIQ::Providers::Azure::NetworkManager::LoadBalancerListener.where(
          :ems_ref => lb_listener_ems_ref).first

        expect(@listener).to have_attributes(
                               "ems_ref"                  => lb_listener_ems_ref,
                               "name"                     => nil,
                               "description"              => nil,
                               "load_balancer_protocol"   => "Tcp",
                               "load_balancer_port_range" => 80...81,
                               "instance_protocol"        => "Tcp",
                               "instance_port_range"      => 80...81,
                               "cloud_tenant_id"          => nil,
                               "type"                     => "ManageIQ::Providers::Azure::NetworkManager::LoadBalancerListener"
                             )
        expect(@listener.ext_management_system).to eq(@ems.network_manager)
        expect(@lb.load_balancer_listeners).to eq [@listener]
        expect(@listener.load_balancer_pools).to eq([@pool])
        expect(@listener.load_balancer_pool_members.collect(&:ems_ref).sort)
          .to match_array [lb_pool_member_1_ems_ref, lb_pool_member_2_ems_ref]

        expect(@listener.vms.collect(&:name).sort).to match_array ["rspec-lb-a", "rspec-lb-b"]
        expect(@lb_no_members.load_balancer_listeners.count).to eq 0
      end

      def assert_specific_load_balancer_health_checks
        health_check_ems_ref = "/subscriptions/#{@ems.subscription}/resourceGroups/"\
                               "miq-azure-test1/providers/Microsoft.Network/loadBalancers/rspec-lb1/"\
                               "probes/rspec-lb-probe"

        @health_check = ManageIQ::Providers::Azure::NetworkManager::LoadBalancerHealthCheck.where(
          :ems_ref => health_check_ems_ref).first

        expect(@health_check).to have_attributes(
                                   "ems_ref"         => health_check_ems_ref,
                                   "name"            => nil,
                                   "protocol"        => "Http",
                                   "port"            => 80,
                                   "url_path"        => "/",
                                   "interval"        => 5,
                                   "cloud_tenant_id" => nil,
                                   "type"            => "ManageIQ::Providers::Azure::NetworkManager::LoadBalancerHealthCheck"
                                 )
        expect(@listener.load_balancer_health_checks.first).to eq @health_check
        expect(@health_check.load_balancer).to eq @lb
        expect(@health_check.load_balancer_health_check_members.count).to eq 2
        expect(@health_check.load_balancer_pool_members.count).to eq 2
        expect(@lb_no_members.load_balancer_health_checks.count).to eq 1
      end

      def assert_specific_security_group
        @sg = ManageIQ::Providers::Azure::NetworkManager::SecurityGroup.where(:name => @device_name).first

        expect(@sg).to have_attributes(
                         :name        => @device_name,
                         :description => 'miq-azure-test1-eastus'
                       )

        expected_firewall_rules = [
          {:host_protocol => "TCP", :direction => "Inbound", :port => 22,  :end_port => 22,  :source_ip_range => "*"},
          {:host_protocol => "TCP", :direction => "Inbound", :port => 80,  :end_port => 80,  :source_ip_range => "*"},
          {:host_protocol => "TCP", :direction => "Inbound", :port => 443, :end_port => 443, :source_ip_range => "*"}
        ]

        expect(@sg.firewall_rules.size).to eq(3)

        @sg.firewall_rules
          .order(:host_protocol, :direction, :port, :end_port, :source_ip_range, :source_security_group_id)
          .zip(expected_firewall_rules)
          .each do |actual, expected|
          expect(actual).to have_attributes(expected)
        end
      end

      def assert_specific_flavor
        @flavor_not_found = ManageIQ::Providers::Azure::CloudManager::Flavor.where(:name => "Basic_A0").first
        expect(@flavor_not_found).to eq(nil)

        @flavor = ManageIQ::Providers::Azure::CloudManager::Flavor.where(:name => "basic_a0").first

        expect(@flavor).to have_attributes(
                             :name                     => "basic_a0",
                             :description              => nil,
                             :enabled                  => true,
                             :cpus                     => 1,
                             :cpu_cores                => 1,
                             :memory                   => 768.megabytes,
                             :supports_32_bit          => nil,
                             :supports_64_bit          => nil,
                             :supports_hvm             => nil,
                             :supports_paravirtual     => nil,
                             :block_storage_based_only => nil,
                             :root_disk_size           => 1023.megabytes,
                             :swap_disk_size           => 20.megabytes
                           )

        expect(@flavor.ext_management_system).to eq(@ems)
      end

      def assert_specific_az
        @avail_zone = ManageIQ::Providers::Azure::CloudManager::AvailabilityZone.first
        expect(@avail_zone).to have_attributes(:name => @ems.name)
      end

      def assert_specific_cloud_network
        name = 'miq-azure-test1'

        cn_resource_id = "/subscriptions/#{@ems.subscription}"\
                         "/resourceGroups/#{@resource_group}/providers/Microsoft.Network"\
                         "/virtualNetworks/#{@resource_group}"

        @cn = CloudNetwork.where(:name => name).first
        @avail_zone = ManageIQ::Providers::Azure::CloudManager::AvailabilityZone.first

        expect(@cn).to have_attributes(
                         :name    => name,
                         :ems_ref => cn_resource_id,
                         :cidr    => "10.16.0.0/16",
                         :status  => nil,
                         :enabled => true
                       )
        expect(@cn.vms.size).to be >= 1
        expect(@cn.network_ports.size).to be >= 1

        vm = @cn.vms.where(:name => @device_name).first
        expect(vm.cloud_networks.size).to be >= 1

        expect(@cn.cloud_subnets.size).to eq(1)
        @subnet = @cn.cloud_subnets.where(:name => "default").first
        expect(@subnet).to have_attributes(
                             :name              => "default",
                             :ems_ref           => "#{cn_resource_id}/subnets/default",
                             :cidr              => "10.16.0.0/24",
                             :availability_zone => @avail_zone
                           )

        vm_subnet = @subnet.vms.where(:name => @device_name).first
        expect(vm_subnet.cloud_subnets.size).to be >= 1
        expect(vm_subnet.network_ports.size).to be >= 1
        expect(vm_subnet.security_groups.size).to be >= 1
        expect(vm_subnet.floating_ips.size).to be >= 1
      end

      def assert_specific_vm_powered_on
        vm = ManageIQ::Providers::Azure::CloudManager::Vm.where(
          :name => @device_name, :raw_power_state => "VM running").first
        vm_resource_id = "#{@ems.subscription}\\#{@resource_group}\\microsoft.compute/virtualmachines\\#{@device_name}"

        expect(vm).to have_attributes(
                        :template              => false,
                        :ems_ref               => vm_resource_id,
                        :ems_ref_obj           => nil,
                        :uid_ems               => vm_resource_id,
                        :vendor                => "azure",
                        :power_state           => "on",
                        :location              => "eastus",
                        :tools_status          => nil,
                        :boot_time             => nil,
                        :standby_action        => nil,
                        :connection_state      => nil,
                        :cpu_affinity          => nil,
                        :memory_reserve        => nil,
                        :memory_reserve_expand => nil,
                        :memory_limit          => nil,
                        :memory_shares         => nil,
                        :memory_shares_level   => nil,
                        :cpu_reserve           => nil,
                        :cpu_reserve_expand    => nil,
                        :cpu_limit             => nil,
                        :cpu_shares            => nil,
                        :cpu_shares_level      => nil
                      )

        expect(vm.ext_management_system).to eql(@ems)
        expect(vm.availability_zone).to eql(@avail_zone)
        expect(vm.flavor).to eql(@flavor)
        expect(vm.operating_system.product_name).to eql("RHEL 7.2")
        expect(vm.custom_attributes.size).to eql(0)
        expect(vm.snapshots.size).to eql(0)

        assert_specific_vm_powered_on_hardware(vm)
      end

      def assert_specific_vm_powered_on_hardware(v)
        expect(v.hardware).to have_attributes(
                                :guest_os            => nil,
                                :guest_os_full_name  => nil,
                                :bios                => nil,
                                :annotation          => nil,
                                :cpu_sockets         => 1,
                                :memory_mb           => 768,
                                :disk_capacity       => 1043.megabyte,
                                :bitness             => nil,
                                :virtualization_type => nil
                              )

        expect(v.hardware.guest_devices.size).to eql(0)
        expect(v.hardware.nics.size).to eql(0)
        floating_ip   = ManageIQ::Providers::Azure::NetworkManager::FloatingIp.where(
          :address => @ip_address).first
        cloud_network = ManageIQ::Providers::Azure::NetworkManager::CloudNetwork.where(
          :name => @resource_group).first
        cloud_subnet  = cloud_network.cloud_subnets.first
        expect(v.floating_ip).to eql(floating_ip)
        expect(v.floating_ips.first).to eql(floating_ip)
        expect(v.floating_ip_addresses.first).to eql(floating_ip.address)
        expect(v.fixed_ip_addresses).to match_array(v.ipaddresses - [floating_ip.address])
        expect(v.fixed_ip_addresses.count).to be > 0

        expect(v.cloud_network).to eql(cloud_network)
        expect(v.cloud_subnet).to eql(cloud_subnet)

        assert_specific_hardware_networks(v)
      end

      def assert_specific_hardware_networks(v)
        expect(v.hardware.networks.size).to eql(2)
        network = v.hardware.networks.where(:description => "public").first
        expect(network).to have_attributes(
                             :description => "public",
                             :ipaddress   => @ip_address,
                             :hostname    => "ipconfig1"
                           )
        network = v.hardware.networks.where(:description => "private").first
        expect(network).to have_attributes(
                             :description => "private",
                             :ipaddress   => "10.16.0.4",
                             :hostname    => "ipconfig1"
                           )
      end

      def assert_specific_disk
        disk = Disk.where(:device_name => @device_name).first

        expect(disk).to have_attributes(
                          :location => "https://miqazuretest18686.blob.core.windows.net/vhds/miq-test-rhel12016218112243.vhd",
                          :size     => 32212255232 # 30gb, approx
                        )
      end

      def assert_specific_vm_with_managed_disks
        vm = Vm.find_by(:name => @managed_vm)
        expect(vm.disks.size).to eq(2)
        expect(vm.disks.collect(&:device_name)).to match_array([@managed_os_disk, @managed_data_disk])
      end

      def assert_specific_managed_disk
        disk = Disk.find_by(:device_name => @managed_os_disk)
        expect(disk.location).to eql("/subscriptions/#{@ems.subscription}/resourceGroups/"\
                                      "MIQ-AZURE-TEST4/providers/Microsoft.Compute/disks/"\
                                      "miqazure-linux-managed_OsDisk_1_7b2bdf790a7d4379ace2846d307730cd")
        expect(disk.size).to eql(32.gigabytes)
      end

      def assert_specific_resource_group
        vm_managed   = Vm.find_by(:name => @managed_vm)
        vm_unmanaged = Vm.find_by(:name => @device_name)

        # VM in eastus, resource group in westus
        vm_mismatch  = Vm.find_by(:name => 'miqmismatch2')

        managed_group = ResourceGroup.find_by(:name => 'miq-azure-test4')
        unmanaged_group = ResourceGroup.find_by(:name => 'miq-azure-test1')
        mismatch_group = ResourceGroup.find_by(:name => 'miq-azure-test3')

        expect(vm_managed.resource_group).to eql(managed_group)
        expect(vm_unmanaged.resource_group).to eql(unmanaged_group)
        expect(vm_mismatch.resource_group).to eql(mismatch_group)
      end

      def assert_specific_vm_powered_off
        vm_name = 'miqazure-centos1'

        v = ManageIQ::Providers::Azure::CloudManager::Vm.where(
          :name            => vm_name,
          :raw_power_state => 'VM deallocated').first

        az1           = ManageIQ::Providers::Azure::CloudManager::AvailabilityZone.first
        floating_ip   = ManageIQ::Providers::Azure::NetworkManager::FloatingIp.where(:address => "miqazure-centos1").first
        cloud_network = ManageIQ::Providers::Azure::NetworkManager::CloudNetwork.where(:name => "miq-azure-test1").first
        cloud_subnet  = cloud_network.cloud_subnets.first

        assert_specific_vm_powered_off_attributes(v)

        expect(v.ext_management_system).to eql(@ems)
        expect(v.availability_zone).to eql(az1)
        expect(v.floating_ip).to eql(floating_ip)
        expect(v.cloud_network).to eql(cloud_network)
        expect(v.cloud_subnet).to eql(cloud_subnet)
        expect(v.operating_system.product_name).to eql('CentOS 7.1')
        expect(v.custom_attributes.size).to eql(0)
        expect(v.snapshots.size).to eql(0)

        assert_specific_vm_powered_off_hardware(v)
      end

      def assert_specific_vm_powered_off_attributes(v)
        name = 'miqazure-centos1'
        vm_resource_id = "#{@ems.subscription}\\#{@resource_group}\\microsoft.compute/virtualmachines\\#{name}"

        expect(v).to have_attributes(
                       :template              => false,
                       :ems_ref               => vm_resource_id,
                       :ems_ref_obj           => nil,
                       :uid_ems               => vm_resource_id,
                       :vendor                => "azure",
                       :power_state           => "off",
                       :location              => "eastus",
                       :tools_status          => nil,
                       :boot_time             => nil,
                       :standby_action        => nil,
                       :connection_state      => nil,
                       :cpu_affinity          => nil,
                       :memory_reserve        => nil,
                       :memory_reserve_expand => nil,
                       :memory_limit          => nil,
                       :memory_shares         => nil,
                       :memory_shares_level   => nil,
                       :cpu_reserve           => nil,
                       :cpu_reserve_expand    => nil,
                       :cpu_limit             => nil,
                       :cpu_shares            => nil,
                       :cpu_shares_level      => nil
                     )
      end

      def assert_specific_vm_powered_off_hardware(v)
        expect(v.hardware).to have_attributes(
                                :guest_os           => nil,
                                :guest_os_full_name => nil,
                                :bios               => nil,
                                :annotation         => nil,
                                :cpu_sockets        => 1,
                                :memory_mb          => 768,
                                :disk_capacity      => 1043.megabytes,
                                :bitness            => nil
                              )

        expect(v.hardware.disks.size).to eql(1)
        expect(v.hardware.guest_devices.size).to eql(0)
        expect(v.hardware.nics.size).to eql(0)
        expect(v.hardware.networks.size).to eql(2)
      end

      def assert_specific_template
        template_resource_id = "https://miqazuretest14047.blob.core.windows.net/system/"\
                               "Microsoft.Compute/Images/miq-test-container/"\
                               "test-win2k12-img-osDisk.e17a95b0-f4fb-4196-93c5-0c8be7d5c536.vhd"

        @template = ManageIQ::Providers::Azure::CloudManager::Template.find_by(:ems_ref => template_resource_id)

        expect(@template).to have_attributes(
                               :template              => true,
                               :ems_ref               => template_resource_id,
                               :ems_ref_obj           => nil,
                               :uid_ems               => template_resource_id,
                               :vendor                => "azure",
                               :power_state           => "never",
                               :location              => "eastus",
                               :tools_status          => nil,
                               :boot_time             => nil,
                               :standby_action        => nil,
                               :connection_state      => nil,
                               :cpu_affinity          => nil,
                               :memory_reserve        => nil,
                               :memory_reserve_expand => nil,
                               :memory_limit          => nil,
                               :memory_shares         => nil,
                               :memory_shares_level   => nil,
                               :cpu_reserve           => nil,
                               :cpu_reserve_expand    => nil,
                               :cpu_limit             => nil,
                               :cpu_shares            => nil,
                               :cpu_shares_level      => nil
                             )

        expect(@template.ext_management_system).to eq(@ems)
        expect(@template.operating_system).to eq(nil)
        expect(@template.custom_attributes.size).to eq(0)
        expect(@template.snapshots.size).to eq(0)

        expect(@template.hardware).to have_attributes(
                                        :guest_os            => "windows_generic",
                                        :guest_os_full_name  => nil,
                                        :bios                => nil,
                                        :annotation          => nil,
                                        :memory_mb           => nil,
                                        :disk_capacity       => nil,
                                        :bitness             => 64,
                                        :virtualization_type => nil,
                                        :root_device_type    => nil
                                      )

        expect(@template.hardware.disks.size).to eq(0)
        expect(@template.hardware.guest_devices.size).to eq(0)
        expect(@template.hardware.nics.size).to eq(0)
        expect(@template.hardware.networks.size).to eq(0)
      end

      def assert_specific_orchestration_template
        @orch_template = ManageIQ::Providers::Azure::CloudManager::OrchestrationTemplate.find_by(
          :name => "spec-nested-deployment-dont-delete"
        )
        expect(@orch_template).to have_attributes(
                                    :md5 => "05e28d9332a3b60def5fbd66ac031a7d"
                                  )
        expect(@orch_template.description).to eql('contentVersion: 1.0.0.0')
        expect(@orch_template.content).to start_with("{\"$schema\":\"http://schema.management.azure.com"\
          "/schemas/2015-01-01/deploymentTemplate.json\"")
      end

      def assert_specific_orchestration_stack
        @orch_stack = ManageIQ::Providers::Azure::CloudManager::OrchestrationStack.find_by(
          :name => "spec-nested-deployment-dont-delete"
        )
        expect(@orch_stack).to have_attributes(
                                 :status         => "Succeeded",
                                 :description    => "spec-nested-deployment-dont-delete",
                                 :resource_group => "miq-azure-test1",
                                 :ems_ref        => "/subscriptions/#{@ems.subscription}/resourceGroups"\
                             "/miq-azure-test1/providers/Microsoft.Resources"\
                             "/deployments/spec-nested-deployment-dont-delete",
                                 )

        assert_specific_orchestration_stack_parameters
        assert_specific_orchestration_stack_resources
        assert_specific_orchestration_stack_outputs
        assert_specific_orchestration_stack_associations
      end

      def assert_specific_orchestration_stack_parameters
        parameters = @orch_stack.parameters.order("ems_ref")
        expect(parameters.size).to eq(14)

        # assert one of the parameter models
        expect(parameters.find { |p| p.name == 'adminUsername' }).to have_attributes(
                                                                       :value   => "deploy1admin",
                                                                       :ems_ref => "/subscriptions/#{@ems.subscription}/resourceGroups"\
                      "/miq-azure-test1/providers/Microsoft.Resources"\
                      "/deployments/spec-nested-deployment-dont-delete\\adminUsername"
                                                                     )
      end

      def assert_specific_orchestration_stack_resources
        resources = @orch_stack.resources.order("ems_ref")
        expect(resources.size).to eq(9)

        # assert one of the resource models
        expect(resources.find { |r| r.name == 'spec0deply1as' }).to have_attributes(
                                                                      :logical_resource       => "spec0deply1as",
                                                                      :physical_resource      => "a2495990-63ae-4ea3-8904-866b7e01ec18",
                                                                      :resource_category      => "Microsoft.Compute/availabilitySets",
                                                                      :resource_status        => "Succeeded",
                                                                      :resource_status_reason => "OK",
                                                                      :ems_ref                => "/subscriptions/#{@ems.subscription}/resourceGroups"\
                                     "/miq-azure-test1/providers/Microsoft.Compute/availabilitySets/spec0deply1as"
                                                                    )
      end

      def assert_specific_orchestration_stack_outputs
        outputs = ManageIQ::Providers::Azure::CloudManager::OrchestrationStack.find_by(
          :name => "spec-deployment-dont-delete").outputs
        expect(outputs.size).to eq(1)
        expect(outputs[0]).to have_attributes(
                                :key         => "siteUri",
                                :value       => "hard-coded output for test",
                                :description => "siteUri",
                                :ems_ref     => "/subscriptions/#{@ems.subscription}/resourceGroups"\
                          "/miq-azure-test1/providers/Microsoft.Resources"\
                          "/deployments/spec-deployment-dont-delete\\siteUri"
                              )
      end

      def assert_specific_orchestration_stack_associations
        # orchestration stack belongs to a provider
        expect(@orch_stack.ext_management_system).to eql(@ems)

        # orchestration stack belongs to an orchestration template
        expect(@orch_stack.orchestration_template).to eql(@orch_template)

        # orchestration stack can be nested
        parent_stack = ManageIQ::Providers::Azure::CloudManager::OrchestrationStack.find_by(
          :name => "spec-deployment-dont-delete")
        expect(@orch_stack.parent).to eql(parent_stack)

        # orchestration stack can have vms
        vm = ManageIQ::Providers::Azure::CloudManager::Vm.find_by(:name => "spec0deply1vm1")
        expect(vm.orchestration_stack).to eql(@orch_stack)

        # orchestration stack can have cloud networks
        cloud_network = CloudNetwork.find_by(:name => 'spec0deply1vnet')
        expect(cloud_network.orchestration_stack).to eql(@orch_stack)
      end

      def assert_specific_nic_and_ip
        nic_group = 'miq-azure-test1' # EastUS
        ip_group  = 'miq-azure-test4' # Also EastUS
        nic_name  = 'miqmismatch1'

        ems_ref_nic = "/subscriptions/#{@ems.subscription}/resourceGroups"\
                   "/#{nic_group}/providers/Microsoft.Network"\
                   "/networkInterfaces/miqmismatch1"

        ems_ref_ip = "/subscriptions/#{@ems.subscription}/resourceGroups"\
                   "/#{ip_group}/providers/Microsoft.Network"\
                   "/publicIPAddresses/miqmismatch1"

        @network_port = ManageIQ::Providers::Azure::NetworkManager::NetworkPort.where(:ems_ref => ems_ref_nic).first
        @floating_ip  = ManageIQ::Providers::Azure::NetworkManager::FloatingIp.where(:ems_ref => ems_ref_ip).first

        expect(@network_port).to have_attributes(
                                   :status  => 'Succeeded',
                                   :name    => nic_name,
                                   :ems_ref => ems_ref_nic
                                 )

        expect(@floating_ip).to have_attributes(
                                  :status  => 'Succeeded',
                                  :address => @mismatch_ip,
                                  :ems_ref => ems_ref_ip,
                                  )

        expect(@network_port.device.id).to eql(@floating_ip.vm.id)
      end
    end
  end
end
