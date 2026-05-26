services:
  producer:
    container_name: producer
    image: ${CARDANO_IMAGE}
    restart: unless-stopped
    security_opt:
      - no-new-privileges
    command: run
    environment:
      - CARDANO_CONFIG=/opt/cardano/config/mainnet/config.json
      - CARDANO_TOPOLOGY=/opt/cardano/config/mainnet/topology.json
      - CARDANO_DATABASE_PATH=/data/db
      - CARDANO_SOCKET_PATH=/ipc/node.socket
      - CARDANO_PORT=6000
      - CARDANO_BLOCK_PRODUCER=true
      - START_AS_NON_PRODUCING=false
      - CARDANO_SHELLEY_KES_KEY=/opt/cardano/config/keys/kes.skey
      - CARDANO_SHELLEY_VRF_KEY=/opt/cardano/config/keys/vrf.skey
      - CARDANO_SHELLEY_OPERATIONAL_CERTIFICATE=/opt/cardano/config/keys/node.cert
      - CARDANO_RTS_OPTS=-N2 -A64m -I0 -qg -qb --disable-delayed-os-memory-return
      - RESTORE_SNAPSHOT=false
    ports:
      - "6000:6000"
      - "127.0.0.1:12798:12798"
    volumes:
      - ${CARDANO_HOME}/db:/data/db
      - ${CARDANO_HOME}/ipc:/ipc
      - ${CARDANO_HOME}/config/mainnet:/opt/cardano/config/mainnet:ro
      - ${CARDANO_HOME}/bp-keys:/opt/cardano/config/keys:ro
