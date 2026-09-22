set installer policy check-for-updates-period 3 
set installer policy periodically-self-update on 
set installer policy auto-compress-snapshot on 
set installer policy self-test install-policy off 
set installer policy self-test network-link-up off 
set installer policy self-test start-processes on 
set arp table cache-size 4096
set arp table validity-timeout 60
set arp announce 2
set ip-conflicts-monitor state off 
set message banner on 

set message motd off 

set consent-flags allow-sending-data true
set consent-flags allow-receiving-data true
set consent-flags allow-sending-crash-data false
set consent-flags allow-receiving-data-non-security true
set expert-authentication-method user-password
set grub2-password-hash grub.pbkdf2.sha512.10000.24921B08071A101225B5295598AC7CB4F524CA34A77AF02B9D9C4D15DDC9B22F1B833DF03A61D41EB6012BACE68817C2A3044D6140AB8741B2FAFEEE0466C511.67DB1F3760C2B301E25ECED06D9AF3BC90C0BB924CFDBA02CDFCE3BF1C14DF9D1139703801002BBCAC6F518FBFB464240DE9898C35B28F82771C58A589DFDBF2
set web session-timeout 720
set web ssl-port 443
set web ssl3-enabled off
set web daemon-enable on
set inactivity-timeout 720
set ipv6-state off
set user admin password-hash $6$rCj/wSlxT7Jork5m$9DL7Pstf3M5NNfBMd32A.Nnob7G69p2/ABC0K0.Kgh.Es/G9UkA84CXU429Q5ZgMK9vTEdk6DbAbX80SPnMb61 
set management interface eth0  
set static-route default nexthop gateway address 10.1.1.1 on
