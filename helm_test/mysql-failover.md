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

root@controlplane:~/gitops-agnocon$ cd ../
root@controlplane:~$ 
root@controlplane:~$ 
root@controlplane:~$ rm -rf *
root@controlplane:~$ 
root@controlplane:~$ 
root@controlplane:~$ git clone https://github.com/allwinrajan/gitops-agnocon.git
Cloning into 'gitops-agnocon'...
Username for 'https://github.com': allwinrajan
Password for 'https://allwinrajan@github.com': 
remote: Enumerating objects: 348, done.
remote: Counting objects: 100% (348/348), done.
remote: Compressing objects: 100% (166/166), done.
remote: Total 348 (delta 166), reused 347 (delta 165), pack-reused 0 (from 0)
Receiving objects: 100% (348/348), 157.78 KiB | 9.86 MiB/s, done.
Resolving deltas: 100% (166/166), done.
root@controlplane:~$ cd gitops-agnocon/
root@controlplane:~/gitops-agnocon$ 
root@controlplane:~/gitops-agnocon$ 
root@controlplane:~/gitops-agnocon$ 
root@controlplane:~/gitops-agnocon$ kubectl apply -f gitops/bootstrap/namespaces.yaml
namespace/admin-app created
namespace/freeswitch created
namespace/influxdb created
namespace/kamailio created
namespace/multus-nad created
namespace/mysql-cluster created
namespace/nats created
namespace/observability created
namespace/postgres-cluster created
namespace/redis created
namespace/rtpengine created
namespace/rustfs created
namespace/watchdog created
root@controlplane:~/gitops-agnocon$ kubectl apply -f gitops/bootstrap/agnocon-project.yaml
appproject.argoproj.io/agnocon created
root@controlplane:~/gitops-agnocon$ kubectl apply -f gitops/applications/applicationset-production.yaml
applicationset.argoproj.io/agnocon-production created
root@controlplane:~/gitops-agnocon$ kubectl apply -f gitops/bootstrap/root-app.yaml
application.argoproj.io/agnocon-root created
root@controlplane:~/gitops-agnocon$ kubectl get pods -n mysql-cluster
NAME                          READY   STATUS     RESTARTS   AGE
mysql-service-primary-0       0/1     Init:0/1   0          26s
mysql-service-secondary-0-0   0/1     Init:0/1   0          26s
mysql-service-secondary-1-0   0/1     Init:0/1   0          26s
root@controlplane:~/gitops-agnocon$ kubectl get pods -n mysql-cluster
NAME                          READY   STATUS    RESTARTS   AGE
mysql-service-primary-0       1/1     Running   0          61s
mysql-service-secondary-0-0   1/1     Running   0          61s
mysql-service-secondary-1-0   1/1     Running   0          61s
root@controlplane:~/gitops-agnocon$ kubectl get pods -n mysql-cluster
NAME                          READY   STATUS    RESTARTS   AGE
mysql-service-primary-0       1/1     Running   0          73s
mysql-service-secondary-0-0   1/1     Running   0          73s
mysql-service-secondary-1-0   1/1     Running   0          73s
root@controlplane:~/gitops-agnocon$ kubectl exec -it -n mysql-cluster mysql-service-primary-0 -- bash
Defaulted container "mysql" out of: mysql, fix-routing (init)
bash-4.4# mysql -uroot -p
Enter password: 
Welcome to the MySQL monitor.  Commands end with ; or \g.
Your MySQL connection id is 72
Server version: 8.0.36 MySQL Community Server - GPL

Copyright (c) 2000, 2024, Oracle and/or its affiliates.

Oracle is a registered trademark of Oracle Corporation and/or its
affiliates. Other names may be trademarks of their respective
owners.

Type 'help;' or '\h' for help. Type '\c' to clear the current input statement.

mysql> show databases;
+--------------------+
| Database           |
+--------------------+
| information_schema |
| mysql              |
| performance_schema |
| sys                |
+--------------------+
4 rows in set (0.01 sec)

mysql> exit
Bye
bash-4.4# exit
exit
root@controlplane:~/gitops-agnocon$ kubectl exec -it -n mysql-cluster mysql-service-primary-0 -- bash
Defaulted container "mysql" out of: mysql, fix-routing (init)
bash-4.4# mysql -uroot -p
Enter password: 
Welcome to the MySQL monitor.  Commands end with ; or \g.
Your MySQL connection id is 105
Server version: 8.0.36 MySQL Community Server - GPL

Copyright (c) 2000, 2024, Oracle and/or its affiliates.

Oracle is a registered trademark of Oracle Corporation and/or its
affiliates. Other names may be trademarks of their respective
owners.

Type 'help;' or '\h' for help. Type '\c' to clear the current input statement.

mysql> CREATE DATABASE failover_test;
Query OK, 1 row affected (0.03 sec)

mysql> USE failover_test;
Database changed
mysql> 
mysql> CREATE TABLE demo (
    ->     id INT PRIMARY KEY,
    ->     name VARCHAR(100)
    -> );
Query OK, 0 rows affected (0.12 sec)

mysql> 
mysql> INSERT INTO demo VALUES (1,'Primary Working');
Query OK, 1 row affected (0.02 sec)

mysql> exit
Bye
bash-4.4# exit
exit
root@controlplane:~/gitops-agnocon$ kubectl exec -it -n mysql-cluster mysql-service-secondary-0-0 -- bash
Defaulted container "mysql" out of: mysql, fix-routing (init)
bash-4.4# mysql -uroot -p
Enter password: 
Welcome to the MySQL monitor.  Commands end with ; or \g.
Your MySQL connection id is 14
Server version: 8.0.36 MySQL Community Server - GPL

Copyright (c) 2000, 2024, Oracle and/or its affiliates.

Oracle is a registered trademark of Oracle Corporation and/or its
affiliates. Other names may be trademarks of their respective
owners.

Type 'help;' or '\h' for help. Type '\c' to clear the current input statement.

mysql> SHOW DATABASES;
+--------------------+
| Database           |
+--------------------+
| information_schema |
| mysql              |
| performance_schema |
| sys                |
+--------------------+
4 rows in set (0.01 sec)

mysql> USE failover_test;
ERROR 1049 (42000): Unknown database 'failover_test'
mysql> SELECT * FROM demo;
ERROR 1046 (3D000): No database selected
mysql> 
mysql> SHOW REPLICA STATUS\G
Empty set (0.00 sec)

mysql> exit
Bye
bash-4.4# exit
exit
root@controlplane:~/gitops-agnocon$ kubectl get pods -n mysql-cluster -w
NAME                          READY   STATUS    RESTARTS   AGE
mysql-service-primary-0       1/1     Running   0          5m39s
mysql-service-secondary-0-0   1/1     Running   0          5m39s
mysql-service-secondary-1-0   1/1     Running   0          5m39s
