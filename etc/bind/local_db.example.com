$TTL  86400
@  IN  SOA  ns1.example.com. webmaster.example.com. (
     2026010100  ; Serial
       604800    ; Refresh
        86400    ; Retry
      2592000    ; Expire
        86400 )  ; Negative Cache TTL
;
@       IN    NS  ns1.example.com.
@       IN    NS  ns2.example.com.
@       IN    A    203.0.113.10
@       IN    MX  10 mail.example.com.
ns1     IN    A   203.0.113.10
ns2     IN    A   203.0.113.10
mail    IN    A   203.0.113.10
www     IN    A   203.0.113.10
app1    IN    A   203.0.113.10
@                      86400    IN TXT   "v=spf1 a mx -all"
_dmarc                 86400    IN TXT   "v=DMARC1; p=quarantine; rua=mailto:webmaster@example.com; adkim=r; aspf=r"
@                      86400    IN CAA   0 issue "letsencrypt.org"
@                      86400    IN CAA   0 issuewild "letsencrypt.org"
