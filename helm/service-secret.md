[sbc-core]

tls:
    [namespace:kamailio]
    - /etc/kamailio/tls/tls.crt via [kamailio-tls-secret]
    - /etc/kamailio/tls/tls.key via [kamailio-tls-secret]

nats:
    [namespace:kamailio] - need to implement
    - /etc/nats/ca.crt via [nats-ca-secret]

[fs-core]

admin-backend:
    [namespace:freeswitch]
    - /etc/truststore/certs/admin-backend-service.crt via [admin-ca-secret]

[rtp-core]
    - none

[routing-service]
    - none

[vesl-service]

nats:
    [namespace:freeswitch]
    - /etc/certs/truststore/ca.crt via [nats-ca-secret]

[acd-service]

nats:
    [namespace:freeswitch]
    - /etc/certs/truststore/ca.crt via [nats-ca-secret]

[admin-backend-service]

tls:
    [namespace:admin-app]
    - /etc/tls/tls.crt via [admin-api-tls-hv-secret]
    - /etc/tls/tls.key via [admin-api-tls-hv-secret]

[workspace-service] - need to implement

tls:
    [namespace:admin-app]
    - /etc/nginx/ssl/tls.crt via [admin-ui-tls-hv-secret]
    - /etc/nginx/ssl/tls.key via [admin-ui-tls-hv-secret]

[admin-frontend-service] - need to implement

tls:
    [namespace:admin-app]
    - /etc/tls/tls.crt via [admin-ui-tls-hv-secret]
    - /etc/tls/tls.key via [admin-ui-tls-hv-secret]

[telegraf] - need to implement

nats:
    [namespace:observability]
    - /etc/nats/ca.crt via [nats-ca-secret]


nad_locate -

     privateInterfaceNamePrefix: macvlan-sbc-core-private
     publicInterfaceNamePrefix: macvlan-sbc-core-public

private - 60,61,62,63,64............
public - 70,71,72,73,74..........