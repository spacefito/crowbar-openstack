#
# Cookbook Name:: glance
# Recipe:: api
#
#

keystone_settings = KeystoneHelper.keystone_settings(node, :glance)
swift_config = Barclamp::Config.load("openstack", "swift")
swift_insecure = CrowbarOpenStackHelper.insecure(swift_config) || keystone_settings["insecure"]
cinder_config = Barclamp::Config.load("openstack", "cinder")
cinder_insecure = CrowbarOpenStackHelper.insecure(cinder_config)

include_recipe "#{@cookbook_name}::common"

package "glance-api" do
  package_name "openstack-glance-api" if ["rhel", "suse"].include?(node[:platform_family])
end

# Install qemu-img (dependency present in suse packages)
case node[:platform_family]
when "debian"
  package "qemu-utils"
when "rhel", "fedora"
  package "qemu-img"
end

keystone_settings = KeystoneHelper.keystone_settings(node, @cookbook_name)
profiler_settings = KeystoneHelper.profiler_settings(node, @cookbook_name)

if node[:glance][:api][:protocol] == "https"
  ssl_setup "setting up ssl for glance" do
    generate_certs node[:glance][:ssl][:generate_certs]
    certfile node[:glance][:ssl][:certfile]
    keyfile node[:glance][:ssl][:keyfile]
    group node[:glance][:group]
    fqdn node[:fqdn]
    cert_required node[:glance][:ssl][:cert_required]
    ca_certs node[:glance][:ssl][:ca_certs]
  end
end

ironics = node_search_with_cache("roles:ironic-server") || []

network_settings = GlanceHelper.network_settings(node)

ha_enabled = node[:glance][:ha][:enabled]
memcached_servers = MemcachedHelper.get_memcached_servers(
  ha_enabled ? CrowbarPacemakerHelper.cluster_nodes(node, "glance-server") : [node]
)

glance_stores = node.default[:glance][:glance_stores].dup
glance_stores += ["vmware"] unless node[:glance][:vsphere][:host].empty?

# glance_stores unconditionally enables cinder and swift stores, so we need
# to install the necessary clients
package "python-cinderclient"
package "python-swiftclient"

directory node[:glance][:filesystem_store_datadir] do
  owner node[:glance][:user]
  group node[:glance][:group]
  mode 0755
  action :create
end

template node[:glance][:api][:config_file] do
  source "glance-api.conf.erb"
  owner "root"
  group node[:glance][:group]
  mode 0640
  variables(
      bind_host: network_settings[:api][:bind_host],
      bind_port: network_settings[:api][:bind_port],
      keystone_settings: keystone_settings,
      memcached_servers: memcached_servers,
      rabbit_settings: fetch_rabbitmq_settings,
      swift_api_insecure: swift_insecure,
      cinder_api_insecure: cinder_insecure,
      enable_v1: node[:glance][:enable_v1],
      glance_stores: glance_stores.join(","),
      profiler_settings: profiler_settings
  )
  notifies :restart, "service[#{node[:glance][:api][:service_name]}]"
end

template "/etc/glance/glance-swift.conf" do
  source "glance-swift.conf.erb"
  owner "root"
  group node[:glance][:group]
  mode 0640
  variables(
    keystone_settings: keystone_settings
  )
  notifies :restart, "service[#{node[:glance][:api][:service_name]}]"
end

# ensure swift tempurl key only if "direct" deploy interface is enabled in ironic
if !swift_config.empty? && node[:glance][:default_store] == "swift" && \
    ironics.any? && ironics.first[:ironic][:enabled_deploy_interfaces].include?("direct")
  swift_command = "swift"
  swift_command << (swift_insecure ? " --insecure" : "")
  env = {
    "OS_USERNAME" => keystone_settings["service_user"],
    "OS_PASSWORD" => keystone_settings["service_password"],
    "OS_PROJECT_NAME" => keystone_settings["service_tenant"],
    "OS_AUTH_URL" => keystone_settings["public_auth_url"],
    "OS_IDENTITY_API_VERSION" => "3"
  }

  get_tempurl_key = "#{swift_command} stat | grep -m1 'Meta Temp-Url-Key:' | awk '{print $3}'"
  tempurl_key = Mixlib::ShellOut.new(get_tempurl_key, environment: env).run_command.stdout.chomp
  # no tempurl key set, set a random one
  if tempurl_key.empty?
    # include the secure_password code
    ::Chef::Recipe.send(:include, Opscode::OpenSSL::Password)

    tempurl_key = secure_password
    execute "set-glance-tempurl-key" do
      command "#{swift_command} post -m 'Temp-Url-Key:#{tempurl_key}'"
      user node[:glance][:user]
      group node[:glance][:group]
      environment env
    end
  end
end

ha_enabled = node[:glance][:ha][:enabled]
my_admin_host = CrowbarHelper.get_host_for_admin_url(node, ha_enabled)
my_public_host = CrowbarHelper.get_host_for_public_url(node, node[:glance][:api][:protocol] == "https", ha_enabled)

# If we let the service bind to all IPs, then the service is obviously usable
# from the public network. Otherwise, the endpoint URL should use the unique
# IP that will be listened on.
if node[:glance][:api][:bind_open_address]
  endpoint_admin_ip = my_admin_host
  endpoint_public_ip = my_public_host
else
  endpoint_admin_ip = my_admin_host
  endpoint_public_ip = my_admin_host
end
api_port = node["glance"]["api"]["bind_port"]
glance_protocol = node[:glance][:api][:protocol]

crowbar_pacemaker_sync_mark "wait-glance_register_service" if ha_enabled

register_auth_hash = { user: keystone_settings["admin_user"],
                       password: keystone_settings["admin_password"],
                       project: keystone_settings["admin_project"] }

keystone_register "register glance service" do
  protocol keystone_settings["protocol"]
  insecure keystone_settings["insecure"]
  host keystone_settings["internal_url_host"]
  port keystone_settings["admin_port"]
  auth register_auth_hash
  service_name "glance"
  service_type "image"
  service_description "Openstack Glance Service"
  action :add_service
end

keystone_register "register glance endpoint" do
  protocol keystone_settings["protocol"]
  insecure keystone_settings["insecure"]
  host keystone_settings["internal_url_host"]
  port keystone_settings["admin_port"]
  auth register_auth_hash
  endpoint_service "glance"
  endpoint_region keystone_settings["endpoint_region"]
  endpoint_publicURL "#{glance_protocol}://#{endpoint_public_ip}:#{api_port}"
  endpoint_adminURL "#{glance_protocol}://#{endpoint_admin_ip}:#{api_port}"
  endpoint_internalURL "#{glance_protocol}://#{endpoint_admin_ip}:#{api_port}"
  action :add_endpoint
end

crowbar_pacemaker_sync_mark "create-glance_register_service" if ha_enabled

template node[:glance][:manage][:config_file] do
  source "glance-manage.conf.erb"
  owner "root"
  group node[:glance][:group]
  mode 0o640
end

crowbar_pacemaker_sync_mark "wait-glance_database" if ha_enabled

is_founder = CrowbarPacemakerHelper.is_cluster_founder?(node)

execute "glance-manage db sync" do
  user node[:glance][:user]
  group node[:glance][:group]
  command "glance-manage db sync"
  # We only do the sync the first time, and only if we're not doing HA or if we
  # are the founder of the HA cluster (so that it's really only done once).
  only_if { !node[:glance][:db_synced] && (!ha_enabled || is_founder) }
end

execute "glance-manage db_load_metadefs" do
  user node[:glance][:user]
  group node[:glance][:group]
  command "glance-manage db_load_metadefs"
  # We only load the metadefs the first time, and only if we're not doing HA or if we
  # are the founder of the HA cluster (so that it's really only done once).
  only_if { !node[:glance][:db_metadefs] && (!ha_enabled || is_founder) }
end

# We want to keep a note that we've done db_sync, so we don't do it again.
# If we were doing that outside a ruby_block, we would add the note in the
# compile phase, before the actual db_sync is done (which is wrong, since it
# could possibly not be reached in case of errors).
ruby_block "mark node for glance db_sync" do
  block do
    node.set[:glance][:db_synced] = true
    node.save
  end
  action :nothing
  subscribes :create, "execute[glance-manage db_load_metadefs]", :immediately
end

crowbar_pacemaker_sync_mark "create-glance_database" if ha_enabled

glance_service "api"
