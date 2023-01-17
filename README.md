# cadquery_arm64
This repo provides a docker file to build cadquery and dependencies (ocp) mainly for arm64v8.

We also provided a fork of the cq-server to view your models.

Just use:
```
# launch cq-server and cq-client
docker compose up -d

# use to access the client
docker compose exec cq-client /bin/bash

# try the example
python example/usage_example.py
```

Enjoy the result!
