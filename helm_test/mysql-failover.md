#

kubectl exec -it -n mysql-cluster mysql-service-primary-0 -- bash

#

mysql -uroot -p

#

CREATE DATABASE failover_test;
USE failover_test;

CREATE TABLE demo (
    id INT PRIMARY KEY,
    name VARCHAR(100)
);

INSERT INTO demo VALUES (1,'Primary Working');

#