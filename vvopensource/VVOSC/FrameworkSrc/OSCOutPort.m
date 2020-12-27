
#import "OSCOutPort.h"
#import "OSCInPort.h"




@implementation OSCOutPort


- (NSString *) description	{
	return [NSString stringWithFormat:@"<OSCOutPort %@:%hd>",addressString,port];
}
+ (id) createWithAddress:(NSString *)a andPort:(unsigned short)p	{
	OSCOutPort		*returnMe = [[OSCOutPort alloc] initWithAddress:a andPort:p];
	if (returnMe == nil)
		return nil;
	return [returnMe autorelease];
}
+ (id) createWithAddress:(NSString *)a andPort:(unsigned short)p labelled:(NSString *)l	{
	OSCOutPort		*returnMe = [[OSCOutPort alloc] initWithAddress:a andPort:p labelled:l];
	if (returnMe == nil)
		return nil;
	return [returnMe autorelease];
}


- (id) initWithAddress:(NSString *)a andPort:(unsigned short)p	{
	return [self initWithAddress:a andPort:p labelled:nil];
}
- (id) initWithAddress:(NSString *)a andPort:(unsigned short)p labelled:(NSString *)l	{
	self = [super init];
	if (self != nil)	{
		deleted = NO;
		sock = -1;
		port = p;
		addressString = [a retain];
		portLabel = [l retain];
		
		if (a==nil || p<1024)	{
			NSLog(@"\t\terr in %s, bailing. a was %@ p was %d",__func__,a,p);
			[self release];
			return nil;
		}
		else if (![self createSocket])	{
			NSLog(@"\t\terr in %s, bailing.  no socket.",__func__);
			[self release];
			return nil;
		}
		
	}
	return self;
}
- (void) dealloc	{
	//NSLog(@"%s",__func__);
	if (!deleted)
		[self prepareToBeDeleted];
	if (addressString != nil)
		[addressString release];
	addressString = nil;
	if (portLabel != nil)
		[portLabel release];
	portLabel = nil;
	[super dealloc];
}
- (void) prepareToBeDeleted	{
	deleted = YES;
}

- (NSDictionary *) createSnapshot	{
	NSMutableDictionary		*returnMe = [NSMutableDictionary dictionaryWithCapacity:0];
	
	if (addressString != nil)	{
		[returnMe setObject:addressString forKey:@"address"];
	}
	
	[returnMe setObject:[NSNumber numberWithInt:port] forKey:@"port"];
	
	if (portLabel != nil)	{
		[returnMe setObject:portLabel forKey:@"portLabel"];
	}
	
	return returnMe;
}

- (BOOL) createSocket	{
	sock = socket(PF_INET, SOCK_DGRAM, IPPROTO_UDP);
	if (sock < 0)	{
		NSLog(@"\t\terr: OSCOutPort couldn't create the socket");
		return NO;
	}
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = inet_addr([addressString cStringUsingEncoding:NSASCIIStringEncoding]);
	memset(addr.sin_zero, '\0', sizeof(addr.sin_zero));
	addr.sin_port = htons(port);
	
	long			bufSize = 65506;
	if (setsockopt(sock,SOL_SOCKET,SO_SNDBUF,&bufSize,sizeof(long)) != 0)	{
		NSLog(@"\t\terr %d at setsockopt() in %s",errno,__func__);
	}
	
	//	if any part of the address string contains "255", this is a broadcast output
	NSRange			bcastRange = [addressString rangeOfString:@"255"];
	if ((bcastRange.location!=NSNotFound)&&(bcastRange.length>0))	{
		int			yes = 1;
		setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &yes, sizeof(yes));
	}
	return YES;
}

- (void) sendThisBundle:(OSCBundle *)b	{
	if ((deleted) || (sock == -1) || (b == nil))
		return;
	
	OSCPacket		*packet = [OSCPacket createWithContent:b];
	
	if (packet != nil)
		[self sendThisPacket:packet];
}
- (void) sendThisMessage:(OSCMessage *)m	{
	
	//NSLog(@"%s ... %@",__func__,m);
	if ((deleted) || (sock == -1) || (m == nil))
		return;
	
	OSCPacket		*newPacket = [OSCPacket createWithContent:m];
	
	if (newPacket != nil)
		[self sendThisPacket:newPacket];
	else
		NSLog(@"\t\terr: couldnt create packet at %s",__func__);
}
- (void) sendThisPacket:(OSCPacket *)p	{
	//NSLog(@"%s",__func__);
	if ((deleted) || (sock == -1) || (p == nil))
		return;
	//	make sure the packet doesn't get released if its pool gets drained while i'm sending it
	[p retain];
	
	int				numBytesSent = -1;
	long			bufferSize = [p bufferLength];
	unsigned char	*buff = [p payload];
	
	if (buff == NULL)	{
		NSLog(@"\t\terr: packet's buffer was null");
		[p release];
		return;
	}
	//	send the packet's data to the destination
	numBytesSent = (int)sendto(sock, buff, bufferSize, 0, (const struct sockaddr *)&addr, sizeof(addr));
	//	make sure the packet can be freed...
	[p release];
}

- (void) setAddressString:(NSString *)n	{
	//NSLog(@"%s ... %@",__func__,n);
	if ((n==nil) || ([addressString isEqualToString:n]))
		return;
	NSRange		bogusCharRange = [n rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]];
	if (bogusCharRange.location != NSNotFound)
		return;
	
	sock = -1;
	if (addressString != nil)
		[addressString release];
	addressString = [n retain];
	[self createSocket];
}
- (void) setPort:(unsigned short)p	{
	if ((p < 1024) || (p == port))
		return;
	sock = -1;
	port = p;
	[self createSocket];
}
- (void) setAddressString:(NSString *)n andPort:(unsigned short)p	{
	//	if the passed address is nil or the port is < 1024, return immediately
	if ((n == nil) || (p < 1024))
		return;
	//	if the new address AND port are the same as the current address/port, return immediately
	if (([n isEqualToString:addressString]) && (p == port))
		return;
	
	sock = -1;
	if (addressString != nil)
		[addressString release];
	addressString = [n retain];
	port = p;
	[self createSocket];
}


- (BOOL) _matchesRawAddress:(unsigned int)a andPort:(unsigned short)p	{
	BOOL		returnMe = NO;
	if (((unsigned int)addr.sin_addr.s_addr==a) && ((unsigned short)addr.sin_port==p))
		returnMe = YES;
	return returnMe;
}
- (BOOL) _matchesRawAddress:(unsigned int)a	{
	BOOL		returnMe = NO;
	if ((unsigned int)addr.sin_addr.s_addr == a)
		returnMe = YES;
	return returnMe;
}


- (NSString *) portLabel	{
	return portLabel;
}
- (void) setPortLabel:(NSString *)n	{
	if (portLabel != nil)	{
		[portLabel release];
	}
	portLabel = nil;
	if (n != nil)	{
		portLabel = [n retain];
	}
}

- (unsigned short) port	{
	return port;
}
- (NSString *) addressString	{
	return addressString;
}
- (struct sockaddr_in *) addr	{
	return &addr;
}


@end
