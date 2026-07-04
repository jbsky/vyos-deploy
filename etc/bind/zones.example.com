zone "example.com" IN {
  update-policy {
    grant tsig-key name _acme-challenge.example.com. TXT;
    grant tsig-key name _acme-challenge.www.example.com. TXT;
    grant tsig-key name _acme-challenge.mail.example.com. TXT;
    grant tsig-key name _acme-challenge.app1.example.com. TXT;
  };
  type master;
  file "/etc/bind/db.example.com";
};
