# BLIP-Cocoa

This is the latest Objective-C implementation of the BLIP network messaging protocol. [Version 2 of BLIP][BLIPDOCS] is layered on WebSockets instead of running directly over a TCP socket. The WebSocket implementation used here is [PocketSocket][POCKETSOCKET]

## "What's BLIP?"

You can think of BLIP as an extension that adds a number of useful features that aren't supported by the [WebSocket][WEBSOCKET] protocol:

* **Request/response:** Messages can have responses, and the responses don't have to be sent in the same order as the original messages. Responses are optional; a message can be sent in no-reply mode if it doesn't need one, otherwise a response (even an empty one) will always be sent after the message is handled.
* **Metadata:** Messages are structured, with a set of key/value headers and a binary body, much like HTTP or MIME messages. Peers can use the metadata to route incoming messages to different handlers, effectively creating multiple independent channels on the same connection.
* **Multiplexing:** Large messages are broken into fragments, and if multiple messages are ready to send their fragments will be interleaved on the connection, so they're sent in parallel. This prevents huge messages from blocking the connection.
* **Priorities:** Messages can be marked Urgent, which gives them higher priority in the multiplexing (but without completely starving normal-priority messages.) This is very useful for streaming media.

## "Oh yeah, I know about BLIP"

The first version of BLIP was released as part of my [MYNetwork][MYNETWORK] library. (It's still available because there are projects using it, but I haven't been actively developing it for a while.) This version of the protocol talked directly to a TCP socket and included its own framing layer.

There was an intermediate version of BLIP in the [WebSockets-Cocoa][WEBSOCKETS_COCOA] library, an implementation of WebSockets I wrote for use in Couchbase Lite 1.0. Couchbase Lite didn't use that BLIP code; it was purely experimental.

This new version has been extensively modified and improved:

* The WebSocket implementation is now [PocketSocket][POCKETSOCKET], instead of my own code based on GCDAsyncSocket. PocketSocket is significantly smaller and its source code is more modern and easier to work with than GCDAsyncSocket's.
* The underlying framing and network transport has been made pluggable. `BLIPConnection` is now an abstract class, with sequential frame delivery and receipt now implemented by subclasses. the `BLIPPocketSocketConnection` subclass uses PocketSocket; this is the class that clients will instantiate. Other implementations (not necessarily even using WebSockets) are possible.
* Significant changes to the [BLIP protocol][BLIPDOCS]. Most importantly, it now supports flow control of frames within a single message, so that a fast sender won't end up flooding a slow receiver.
* The API supports streaming message bodies, on either the sending or receiving end, so large messages can be sent without eating up a lot of memory. 
* Message compression/decompression is now incremental, which also reduces memory usage.
* The old BLIPDispatcher class has been removed in favor of a simple way to register an action message to be sent to the connection's delegate when messages with a specific profile arrive.


[WEBSOCKET]: http://www.websocket.org
[POCKETSOCKET]: https://github.com/zwopple/PocketSocket
[MYNETWORK]: https://github.com/snej/mynetwork
[WEBSOCKETS_COCOA]: https://github.com/couchbaselabs/WebSockets-Cocoa
[BLIPDOCS]: Docs/BLIP%20Protocol.md
