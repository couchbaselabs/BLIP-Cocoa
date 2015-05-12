!logo.png!

# The BLIP Protocol

**Version 1.1**

By [Jens Alfke](mailto:jens@mooseyard.com) (2008)

## 1. Messages

The BLIP protocol runs over a bidirectional stream, typically a TCP socket, and allows the peers on either end to send **messages** back and forth. The two types of messages are called **requests** and **responses**. Either peer may send a request at any time, to which the other peer will send back a response (unless the request has a special flag that indicates that it doesn't need a response.)

Messages have a structure similar to HTTP entities. Every message (request or response) has a **body**, and zero or more **properties**, or key-value pairs. The body is an uninterpreted sequence of bytes, up to 2^32-1 bytes long. Property keys and values must be UTF-8 strings, and the total size of properties cannot exceed 64k bytes.

Every message has a **request Number:** Requests are numbered sequentially, starting from 1 when the connection opens. Each peer has its own independent sequence for numbering the requests that it sends. Each response is given the number of the corresponding request.

### 1.1. Message Flags

Every request or response message has a set of flags that can be set by the application when it's created:

* **Compressed:** If this flag is set, the body of the message (but not the property data!) will be compressed in transit via the gzip algorithm.
* **Urgent:** The implementation will attempt to expedite delivery of messages with this flag, by allocating them a greater share of the available bandwidth (but not to the extent of completely starving non-urgent messages.)
* **No-Reply**: This request does not need or expect a response. (This flag has no meaning in a response.)
* **Meta**: This flag indicates a message intended for internal use by the peer's BLIP implementation, and should not be delivered directly to the client application. (An example is the "bye" request used to negotiate closing the connection.)

### 1.2. Error Replies

A reply can indicate an error, at either the BLIP level (i.e. couldn't deliver the request to the recipient application) or the application level. In an error reply, the message properties provide information about the error:

* The "Error-Code" property's value is a decimal integer expressed in ASCII, in the range of a signed 32-bit integer.
* The "Error-Domain" property's value is a string denoting a domain in which the error code should be interpreted. If missing, its default value is "BLIP".
* Other properties may provide additional data about the error; applications can define their own schema for this.

The "BLIP" error domain uses the HTTP status codes, insofar as they make sense, as its error codes. The ones used thus far are:

```
BadRequest = 400,
Forbidden = 403,
NotFound = 404,
BadRange = 416,
HandlerFailed = 501,
Unspecified = 599 
```

Other error domains are application-specific, undefined by the protocol itself.

(**Note:** The Objective-C implementation encodes Foundation framework NSErrors into error responses by storing the NSError's code and domain as the BLIP Error-Code and Error-Domain properties, and adding the contents of the NSError's userInfo dictionary as additional properties. When receiving an error response it decodes an NSError in the same way. This behavior is of course platform-specific, and is a convenience not mandated by the protocol.)

## 2. Message Delivery

Messages are **multiplexed** over the connection, so several may be in transit at once. This ensures that a long message doesn't block the delivery of others. It does mean that, on the receiving end, messages will not necessarily be _completed_ in order: if request number 3 is longer than average, then requests 4 and 6 might finish before it does and be delivered to the application first.

However, BLIP does guarantee that requests are _begun_ in order: the receiving peer will always get the first **frame** (chunk of bytes) of request number 3 before the first frame of any higher-numbered request.

The two peers can each send messages at whatever pace they wish. They don't have to take turns. Either peer can send a request whenever it wants.

Every incoming request must be responded to unless its "no-reply" flag is set. However, requests do not need to be responded to in order, and there's no built-in constraint on how long a peer can take to respond. If a peer has nothing meaningful to send back, but must respond, it can send back an empty response (with no properties and zero-length body.)

## 3. Protocol Details

### 3.1. The Connection

The connection between the two peers is opened in the normal way for the underlying protocol (i.e. TCP); BLIP doesn't specify how this happens.

BLIP can run over SSL/TLS. There is no in-band negotiation of whether to use SSL (unlike [[BLIP/BEEP|BEEP]]), so the application code is responsible for telling the BLIP implementation whether or not to use it before the connection opens. Once the SSL handshake, and certificate authentication, complete, BLIP begins just as if it had just opened a regular unencrypted connection.

There are currently no greetings or other preliminaries sent when the connection opens. Either peer (or both peers) just start sending messages when ready. [A special greeting message may be defined in the future.]

### 3.2. Closing The Connection

To initiate closing the connection, the peer does the following:

1. It sends a special request, with the "meta" flag set and the "Profile" property set to the string "Bye".
2. It waits for a response. While waiting it must not send any further requests, although it must continue sending frames of requests that are already being sent, and must send responses to any incoming requests. 
3. Upon receiving a response to the "bye" request, if the response contains an error, the attempt to close has failed (most likely because the other peer refused) and the peer should return to the normal open state. If the close request was initiated by client code, it should notify the client of the failure.
4. Otherwise, if the response was successful, the peer must wait until all of its outgoing responses have been completely sent, and until all of its requests have received a complete response. It can then close the socket.

The protocol for receiving a close request is similar:

1. The peer decides whether to accept or refuse the request, probably by asking the client code. If it accepts, it sends back an empty response. If it refuses, it sends back an error response (403 Forbidden is the default error code) and remains in the regular "open" state.
2. After accepting the close, the peer goes into the same waiting state as in step 4 above. It must not send any new requests, although it must continue sending any partially-sent messages and must reply to responses; and it must wait until all responses are sent and all requests have been responded to before closing the socket.

Note that it's possible for both peers to decide to close the connection simultaneously, which means their "bye" requests will "cross in the mail". They should handle this gracefully. If a peer has sent a "bye" request and receives one from the other peer, it should respond affirmatively and continue waiting for its reply.

Note also that both peers are likely to close the socket at almost the same time, since each will be waiting for the final frames to be sent/received. This means that if a peer receives an EOF on the socket, it should check whether it's already ready to close the socket itself (i.e. it's exchanged "bye"s and has no pending frames to send or receive); if so, it should treat the EOF as a normal close, just as if it had closed the socket itself. (Otherwise, of course, the EOF is unexpected and should be treated as a fatal error.)

### 3.3. Sending Messages

Outgoing messages are multiplexed over the peer's output stream, so that multiple large messages may be sent at once. Each message is encoded as binary data (including compression of the body, if desired) and that data is broken into a sequence of **frames**. Frames must be less than 64k, and are typically 4k. The multiplexer then repeatedly chooses a message that's ready to send, and sends its next frame over the output stream. The algorithm works like this:

1. When the application submits a new message to be sent, the BLIP implementation assigns it a number: if it's a request it gets the next available request number, and if it's a response it gets the number of its corresponding request. It then puts the message into the out-box queue.
2. When the output stream is ready to send data, the BLIP implementation pops the first message from the head of the out-box and removes its next frame.
3. If the message has more frames remaining after this one, a **more-coming** flag is set in the frame's header, and the message is placed back into the out-box queue.
4. The frame is sent over the output stream.

Normal messages are always placed into the queue at the tail end, which results in round-robin scheduling. Urgent messages follow a more complex rule:

* An urgent message is placed after the last other urgent message in the queue. 
* If there are one or more normal messages after that one, the message is inserted after the _first_ normal message (this prevents normal messages from being starved and never reaching the head of the queue.) Or if there are no urgent messages in the queue, the message is placed after the first normal message. If there are no messages at all, then there's only one place to put the message, of course.
* When a newly-ready urgent message is being added to the queue for the _first time_ (in step 1 above), it has the additional restriction that it must go _after_ any other message that has not yet had any of its frames sent. (This is so that messages are begun in sequential order; otherwise the first frame of urgent message number 10 might be sent before the first frame of regular message number 8, for example.)

### 3.4. Receiving Messages

The receiver simply reads the frames one at a time from the input stream and uses their message types and request numbers to group them together into messages. 

When the current frame does not have its more-coming flag set, that message is complete. Its properties are decoded, its body is decompressed if necessary, and the message is delivered to the application.

### 3.5. Message Encoding

A message is encoded into binary data, prior to being broken into frames, as follows:

1. The properties are written out in pairs as alternating key and value strings. Each string is in C format: UTF-8 characters ending with a NUL byte. There is no padding.
2. Certain common strings are abbreviated using a hardcoded dictionary. The abbreviations are strings consisting of a single control character (the ascii value of the character is the index of the string in the dictionary, starting at 1.) The current dictionary can be found in BLIPProperties.m in the reference implementation.
3. The total length in bytes of the encoded properties is prepended to the property data as a 16-bit integer in network byte order (big-endian). **Important Note:** If there are no properties, the length (zero) still needs to be written!
4. If the message's "compressed" flag is set, the body is compressed using the gzip "deflate" algorithm.
5. The body is appended to the property data.

### 3.6. Framing

Frames — chunks of messages — are what is actually written to the stream. Each frame needs a header to identify it to the reader. The header is a fixed 12 bytes long and consists of the following fields, each in network byte order (big-endian):

```
[4 bytes] Magic Number
[4 bytes] Request Number
[2 bytes] Flags
[2 bytes] Frame Size
```

The Magic Number is a fixed constant defined as hexadecimal `9B34F206` [changed from the 9B34F205 used in protocol version 1!].
The Request Number is the serial number of the request, as described above.
The Flags are the message flags, plus a frame-level "more-coming" flag, as described above.
The Frame Size is the total size in bytes of the frame, _including the header_.

The flags are defined as follows:
```
TypeMask  = 0x000F
Compressed= 0x0010
Urgent    = 0x0020
NoReply   = 0x0040
MoreComing= 0x0080
Meta      = 0x0100
```

The TypeMask is actually a 4-bit integer, not a flag. Of the 16 possible message types, the ones currently defined are 0 for a request, 1 for a reply, and 2 for an error reply. [The error-reply type is likely to disappear in the future, though.]

The frame data follows after the header, of course. There is no trailer; each frame's header follows right after the previous frame's data.

### 3.7. Protocol Error Handling

Many types of errors could be found in the incoming data stream while the receiver is parsing it. Some errors are fatal, and the peer should respond by immediately closing the connection. Other errors, called frame errors, can be handled by ignoring the frame and going on to the next.

Fatal errors are:

* Unexpected EOF on input stream (i.e. in mid-frame)
* Wrong frame magic number
* Frame Size value less than 12

Frame errors are:

* Unknown message type (neither request nor response)
* Request number refers to an already-completed request or response (i.e. a prior frame with this number had its "more-coming" flag set to false)
* A property string contains invalid UTF-8
* The property data's length field is longer than the remaining frame data
* The property data, if non-empty, does not end with a NUL byte
* The body of a compressed frame fails to decompress

Note that it is _not_ an error if:

* Undefined flag bits are set (except for the ones that encode the message type). These bits can be ignored.
* Property keys are not recognized by the application (BLIP itself doesn't care what the property keys mean. It's up to the application to decide what to do about such properties.)
