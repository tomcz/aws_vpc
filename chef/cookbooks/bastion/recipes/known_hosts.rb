file "/home/#{node[:bastion][:user]}/.ssh/known_hosts" do
  action :delete
  backup false
end
