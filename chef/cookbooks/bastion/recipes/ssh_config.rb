template "ssh_config" do
  source "ssh_config.erb"
  path   "/home/#{node[:bastion][:user]}/.ssh/config"
  owner  node[:bastion][:user]
  group  node[:bastion][:user]
  mode   "0600"
end
