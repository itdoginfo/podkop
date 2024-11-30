# Shadowsocks
Тут всё просто

## Shadowsocks-old
```
ss://YWVzLTI1Ni1nY206RmJwUDJnSStPczJKK1kzdkVhTnVuOUZ2ZjJZYUhNUlN1L1BBdEVqMks1VT0@example.com:80?type=tcp#example-ss-old
```

## Shadowsocks-2022
```
ss://2022-blake3-aes-128-gcm:5NgF%2B9eM8h4OnrTbHp%2B8UA%3D%3D%3Am8tbs5aKLYG7dN9f3xsiKA%3D%3D@example.com:80#example-ss2022
```

```
ss://MjAyMi1ibGFrZTMtYWVzLTEyOC1nY206Y21lZklCdDhwMTJaZm1QWUplMnNCNThRd3R3NXNKeVpUV0Z6ZENKV2taOD06eEJHZUxiMWNPTjFIeE9CenF6UlN0VFdhUUh6YWM2cFhRVFNZd2dVV2R1RT0@example.com:81?type=tcp#example-ss2022
```
Может быть без `?type=tcp`

# VLESS

## Reality
```
vless://eb445f4b-ddb4-4c79-86d5-0833fc674379@example.com:443?type=tcp&security=reality&pbk=ARQzddtXPJZHinwkPbgVpah9uwPTuzdjU9GpbUkQJkc&fp=chrome&sni=yahoo.com&sid=6cabf01472a3&spx=%2F&flow=xtls-rprx-vision#vless-reality
```

```
vless://UUID@IP:2082?security=reality&sni=dash.cloudflare.com&alpn=h2,http/1.1&allowInsecure=1&fp=chrome&pbk=pukkey&sid=id&type=grpc&encryption=none#vless-reality-strange
```

## TLS
1. 
```
vless://8100b6eb-3fd1-4e73-8ccf-b4ac961232d6@example.com:443?type=tcp&security=tls&fp=&alpn=h3%2Ch2%2Chttp%2F1.1#vless-tls
```

2.
```
vless://8b60389a-7a01-4365-9244-c87f12bb98cf@example.com:443?security=tls&sni=SITE&fp=chrome&type=tcp&flow=xtls-rprx-vision&encryption=none#vless-tls-withot-alpn
```
3. 
```
vless://8b60389a-7a01-4365-9244-c87f12bb98cf@example.com:443/?type=ws&encryption=none&path=%2Fwebsocket&security=tls&sni=sni.server.com&fp=chrome#vless-tls-ws
```

4.
```
vless://[someid]@[someserver]?security=tls&sni=[somesni]&type=ws&path=/?ed%3D2560&host=[somesni]&encryption=none#vless-tls-ws-2
```

5.
```
vless://uuid@server:443?security=tls&sni=server&fp=chrome&type=ws&path=/websocket&encryption=none#vless-tls-ws-3
```

6.
```
vless://33333@example.com:443/?type=ws&encryption=none&path=%2Fwebsocket&security=tls&sni=example.com&fp=chrome#vless-tls-ws-4
```

## No security
```
vless://8b60389a-7a01-4365-9244-c87f12bb98cf@example.com:443?type=tcp&security=none#vless-tls-no-encrypt
```