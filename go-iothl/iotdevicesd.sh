#!/bin/bash

FABRIC_CFG_PATH="/etc/hyperledger/fabric" 
CHANNEL_NAME="mychannel"
DELAY="60"
TIMEOUT="10000000"
COUNTER=1
MAX_RETRY=5
ORDERER_CA=/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/ordererOrganizations/iot.net/orderers/orderer.iot.net/msp/tlscacerts/tlsca.iot.net-cert.pem

echo "Channel name : "$CHANNEL_NAME#

# verify the result of the end-to-end test
verifyResult () {
	if [ $1 -ne 0 ] ; then
		echo "!!!!!!!!!!!!!!! "$2" !!!!!!!!!!!!!!!!"
    echo "========= ERROR !!! FAILED to execute End-2-End Scenario ==========="
		echo
   		exit 1
	fi
}

setGlobals () {

	if [ $1 -eq 0 -o $1 -eq 1 ] ; then
		CORE_PEER_LOCALMSPID="acmeMSP"
		CORE_PEER_TLS_ROOTCERT_FILE=/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/peerOrganizations/acme.iot.net/peers/peer0.acme.iot.net/tls/ca.crt
		CORE_PEER_MSPCONFIGPATH=/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/peerOrganizations/acme.iot.net/users/Admin@acme.iot.net/msp
		if [ $1 -eq 0 ]; then
			CORE_PEER_ADDRESS=peer0.acme.iot.net:7051
		else
			CORE_PEER_ADDRESS=peer1.acme.iot.net:7051
			CORE_PEER_MSPCONFIGPATH=/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/peerOrganizations/acme.iot.net/users/Admin@acme.iot.net/msp
		fi
	fi
	CORE_LOGGING_LEVEL=DEBUG
    CORE_PEER_TLS_ENABLED=true
    CORE_PEER_GOSSIP_USELEADERELECTION=true
    CORE_PEER_GOSSIP_ORGLEADER=false
    CORE_PEER_PROFILE_ENABLED=true
    CORE_PEER_TLS_CERT_FILE=/etc/hyperledger/fabric/tls/server.crt
    CORE_PEER_TLS_KEY_FILE=/etc/hyperledger/fabric/tls/server.key
    CORE_PEER_TLS_ROOTCERT_FILE=/etc/hyperledger/fabric/tls/ca.crt
	CORE_PEER_ID=peer2.acme.iot.net
    CORE_PEER_ADDRESS=peer2.acme.iot.net:7051
    CORE_PEER_GOSSIP_EXTERNALENDPOINT=peer2.acme.iot.net:7051
    CORE_PEER_GOSSIP_BOOTSTRAP=peer0.acme.iot.net:7051
    CORE_PEER_LOCALMSPID=acmeMSP
	env |grep CORE
}

updateAnchorPeers() {
  PEER=$1
  setGlobals $PEER

  if [ -z "$CORE_PEER_TLS_ENABLED" -o "$CORE_PEER_TLS_ENABLED" = "false" ]; then
		peer channel update -o orderer.iot.net:7050 -c $CHANNEL_NAME -f ./channel-artifacts/${CORE_PEER_LOCALMSPID}anchors.tx >&logiot.txt
	else
		peer channel update -o orderer.iot.net:7050 -c $CHANNEL_NAME -f ./channel-artifacts/${CORE_PEER_LOCALMSPID}anchors.tx --tls $CORE_PEER_TLS_ENABLED --cafile $ORDERER_CA >&logiot.txt
	fi
	res=$?
	cat log-iot.txt
	verifyResult $res "Anchor peer update failed"
	echo "===================== Anchor peers for org \"$CORE_PEER_LOCALMSPID\" on \"$CHANNEL_NAME\" is updated successfully ===================== "
	sleep $DELAY
	echo
}

## Sometimes Join takes time hence RETRY atleast for 5 times
joinWithRetry () {
	peer channel join -b $CHANNEL_NAME.block  >&log-iot.txt
	res=$?
	cat log-iot.txt
	if [ $res -ne 0 -a $COUNTER -lt $MAX_RETRY ]; then
		COUNTER=` expr $COUNTER + 1`
		echo "PEER$1 failed to join the channel, Retry after 2 seconds"
		sleep $DELAY
		joinWithRetry $1
	else
		COUNTER=1
	fi
  verifyResult $res "After $MAX_RETRY attempts, PEER$ch has failed to Join the Channel"
}

joinChannel () {
		setGlobals 2
		joinWithRetry 2
		echo "===================== PEER2 joined on the channel \"$CHANNEL_NAME\" ===================== "
		sleep $DELAY
		echo
}

installChaincode () {
	PEER=$1
	setGlobals $PEER
	peer chaincode install -n mycc -v 1.0 -p github.com/M0Rf30/chaincode >&log-iot.txt
	res=$?
	cat log-iot.txt
        verifyResult $res "Chaincode installation on remote peer PEER$PEER has Failed"
	echo "===================== Chaincode is installed on remote peer PEER$PEER ===================== "
	echo
}

instantiateChaincode () {
	PEER=$1
	setGlobals $PEER
	# while 'peer chaincode' command can get the orderer endpoint from the peer (if join was successful),
	# lets supply it directly as we know it using the "-o" option
	if [ -z "$CORE_PEER_TLS_ENABLED" -o "$CORE_PEER_TLS_ENABLED" = "false" ]; then
		peer chaincode instantiate -o orderer.iot.net:7050 -C $CHANNEL_NAME -n mycc -v 1.0 -c "$(iotdevices)" -P "OR	('acmeMSP.member')" >&log-iot.txt
	else
		peer chaincode instantiate -o orderer.iot.net:7050 --tls $CORE_PEER_TLS_ENABLED --cafile $ORDERER_CA -C $CHANNEL_NAME -n mycc -v 1.0 -c '{"Args":["a","b"]}' -P "OR	('acmeMSP.member')" >&log-iot.txt
	fi
	res=$?
	cat log-iot.txt
	verifyResult $res "Chaincode instantiation on PEER$PEER on channel '$CHANNEL_NAME' failed"
	echo "===================== Chaincode Instantiation on PEER$PEER on channel '$CHANNEL_NAME' is successful ===================== "
	echo
}

chaincodeQuery () {
  PEER=$1
  echo "===================== Querying on PEER$PEER on channel '$CHANNEL_NAME'... ===================== "
  setGlobals $PEER
  local rc=1
  local starttime=$(date +%s)

  # continue to poll
  # we either get a successful response, or reach TIMEOUT
  while test "$(($(date +%s)-starttime))" -lt "$TIMEOUT" -a $rc -ne 0
  do
     sleep $DELAY
     echo "Attempting to Query PEER$PEER ...$(($(date +%s)-starttime)) secs"
     peer chaincode query -C $CHANNEL_NAME -n mycc -c '{"Args":["query","a"]}' >&log-iot.txt
     test $? -eq 0 && VALUE=$(cat log-iot.txt | awk '/Query Result/ {print $NF}')
     let rc=0
  done
  echo
  cat log-iot.txt
  if test $rc -eq 0 ; then
	echo "===================== Query on PEER$PEER on channel '$CHANNEL_NAME' is successful ===================== "
  else
	echo "!!!!!!!!!!!!!!! Query result on PEER$PEER is INVALID !!!!!!!!!!!!!!!!"
        echo "================== ERROR !!! FAILED to execute End-2-End Scenario =================="
	echo
	exit 1
  fi
}

chaincodeInvoke () {
	PEER=$1
	setGlobals $PEER
	# while 'peer chaincode' command can get the orderer endpoint from the peer (if join was successful),
	# lets supply it directly as we know it using the "-o" option
	if [ -z "$CORE_PEER_TLS_ENABLED" -o "$CORE_PEER_TLS_ENABLED" = "false" ]; then
		peer chaincode invoke -o orderer.iot.net:7050 -C $CHANNEL_NAME -n mycc -c '{"Args":["transfer","a","b"]}' >&log-iot.txt
	else
		peer chaincode invoke -o orderer.iot.net:7050  --tls $CORE_PEER_TLS_ENABLED --cafile $ORDERER_CA -C $CHANNEL_NAME -n mycc -c '{"Args":["invoke","a","b"]}' >&log-iot.txt
	fi
	res=$?
	cat log-iot.txt
	verifyResult $res "Invoke execution on PEER$PEER failed "
	echo "===================== Invoke transaction on PEER$PEER on channel '$CHANNEL_NAME' is successful ===================== "
	echo
}

## Join all the peers to the channel
echo "Having all peers join the channel..."
joinChannel

## Set the anchor peers for each org in the channel
echo "Updating anchor peers for acme..."
#updateAnchorPeers 0

## Install chaincode on Peer0/acme
echo "Installing chaincode on acme/peer0..."
#installChaincode 0

#Instantiate chaincode on Peer0/acme
echo "Instantiating chaincode on acme/peer0..."
instantiateChaincode 0

#Query on chaincode on Peer0/acme
echo "Querying chaincode on acme/peer0..."
chaincodeQuery 0

#Invoke on chaincode on Peer0/acme
echo "Sending invoke transaction on acme/peer0..."
chaincodeInvoke 0

echo
echo "========= All GOOD, BYFN execution completed =========== "
echo

echo
echo " _____   _   _   ____   "
echo "| ____| | \ | | |  _ \  "
echo "|  _|   |  \| | | | | | "
echo "| |___  | |\  | | |_| | "
echo "|_____| |_| \_| |____/  "
echo

exit 0
