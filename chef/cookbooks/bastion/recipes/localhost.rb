hostsfile_entry '127.0.0.1' do
  comment  'Allow sudo to resolve hostname'
  hostname `hostname`.strip
  action   :append
end
