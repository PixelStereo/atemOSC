/* -LICENSE-START-
 ** Copyright (c) 2011 Blackmagic Design
 **
 ** Permission is hereby granted, free of charge, to any person or organization
 ** obtaining a copy of the software and accompanying documentation covered by
 ** this license (the "Software") to use, reproduce, display, distribute,
 ** execute, and transmit the Software, and to prepare derivative works of the
 ** Software, and to permit third-parties to whom the Software is furnished to
 ** do so, all subject to the following:
 **
 ** The copyright notices in the Software and this entire statement, including
 ** the above license grant, this restriction and the following disclaimer,
 ** must be included in all copies of the Software, in whole or in part, and
 ** all derivative works of the Software, unless such copies or derivative
 ** works are solely in the form of machine-executable object code generated by
 ** a source language processor.
 **
 ** THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 ** IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 ** FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
 ** SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
 ** FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
 ** ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 ** DEALINGS IN THE SOFTWARE.
 ** -LICENSE-END-
 */

#import "AppDelegate.h"
#include <libkern/OSAtomic.h>
#import "OSCAddressPanel.h"
#import "SettingsWindow.h"

@implementation AppDelegate

@synthesize window;
@synthesize isConnectedToATEM;
@synthesize mMixEffectBlock;
@synthesize mMixEffectBlockMonitor;
@synthesize keyers;
@synthesize dsk;
@synthesize switcherTransitionParameters;
@synthesize mMediaPool;
@synthesize mMediaPlayers;
@synthesize mStills;
@synthesize mMacroPool;
@synthesize mSuperSource;
@synthesize mMacroControl;
@synthesize mSuperSourceBoxes;
@synthesize mSwitcherInputAuxList;
@synthesize mAudioInputs;
@synthesize mAudioInputMonitors;
@synthesize mAudioMixer;
@synthesize mAudioMixerMonitor;
@synthesize outPort;
@synthesize inPort;
@synthesize mSwitcher;

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
	NSMenu* edit = [[[[NSApplication sharedApplication] mainMenu] itemWithTitle: @"Edit"] submenu];
	if ([[edit itemAtIndex: [edit numberOfItems] - 1] action] == NSSelectorFromString(@"orderFrontCharacterPalette:"))
		[edit removeItemAtIndex: [edit numberOfItems] - 1];
	if ([[edit itemAtIndex: [edit numberOfItems] - 1] action] == NSSelectorFromString(@"startDictation:"))
		[edit removeItemAtIndex: [edit numberOfItems] - 1];
	if ([[edit itemAtIndex: [edit numberOfItems] - 1] isSeparatorItem])
		[edit removeItemAtIndex: [edit numberOfItems] - 1];
	
	mSwitcherDiscovery = NULL;
	mSwitcher = NULL;
	mMixEffectBlock = NULL;
	mMediaPool = NULL;
	mMacroPool = NULL;
	isConnectedToATEM = NO;
	
	mOscReceiver = [[OSCReceiver alloc] initWithDelegate:self];
	
	mSwitcherMonitor = new SwitcherMonitor(self);
	mMonitors.push_back(mSwitcherMonitor);
	mDownstreamKeyerMonitor = new DownstreamKeyerMonitor(self);
	mMonitors.push_back(mDownstreamKeyerMonitor);
	mUpstreamKeyerMonitor = new UpstreamKeyerMonitor(self);
	mMonitors.push_back(mUpstreamKeyerMonitor);
	mTransitionParametersMonitor = new TransitionParametersMonitor(self);
	mMonitors.push_back(mTransitionParametersMonitor);
	mMixEffectBlockMonitor = new MixEffectBlockMonitor(self);
	mMonitors.push_back(mMixEffectBlockMonitor);
	mMacroPoolMonitor = new MacroPoolMonitor(self);
	mMonitors.push_back(mMacroPoolMonitor);
	mAudioMixerMonitor = new AudioMixerMonitor(self);
	mMonitors.push_back(mAudioMixerMonitor);
	
	[logTextView setTextColor:[NSColor whiteColor]];
	
	[(SettingsWindow *)window loadSettingsFromPreferences];
	
	mSwitcherDiscovery = CreateBMDSwitcherDiscoveryInstance();
	if (!mSwitcherDiscovery)
	{
		NSBeginAlertSheet(@"Could not create Switcher Discovery Instance.\nATEM Switcher Software may not be installed.\n",
						  @"OK", nil, nil, window, self, @selector(sheetDidEndShouldTerminate:returnCode:contextInfo:), NULL, window, @"");
	}
	else
	{
		[self switcherDisconnected];		// start with switcher disconnected
		
		//	make an osc manager- i'm using a custom in-port to record a bunch of extra conversion for the display, but you can just make a "normal" manager
		manager = [[OSCManager alloc] init];
		
		NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];

		int incomingPort = 3333, outgoingPort = 4444;
		NSString *outIpStr = nil;
		if ([prefs integerForKey:@"outgoing"])
			outgoingPort = (int) [prefs integerForKey:@"outgoing"];
		if ([prefs integerForKey:@"incoming"])
			incomingPort = (int) [prefs integerForKey:@"incoming"];
		if ([prefs stringForKey:@"oscdevice"])
			outIpStr = [prefs stringForKey:@"oscdevice"];

		[self portChanged:incomingPort out:outgoingPort ip:outIpStr];
	}
}

- (void)portChanged:(int)inPortValue out:(int)outPortValue ip:(NSString *)outIpStr
{
	[manager removeInput:inPort];

	if (outIpStr != nil)
	{
		[manager removeOutput:outPort];
		outPort = [manager createNewOutputToAddress:outIpStr atPort:outPortValue withLabel:@"atemOSC"];
	}

	inPort = [manager createNewInputForPort:inPortValue withLabel:@"atemOSC"];

	[manager setDelegate:mOscReceiver];
}

- (void)applicationWillTerminate:(NSNotification*)aNotification
{
	[self cleanUpConnection];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender
{
	return YES;
}

- (void)sheetDidEndShouldTerminate:(NSWindow *)sheet returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo
{
	[NSApp terminate:self];
}

- (IBAction)githubPageButtonPressed:(id)sender
{
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/danielbuechele/atemOSC/"]];
}

- (void)connectBMD
{
	dispatch_async(dispatch_get_main_queue(), ^{
		NSString* address = [(SettingsWindow *)window switcherAddress];
		
		dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0ul);
		dispatch_async(queue, ^{
			
			BMDSwitcherConnectToFailure            failReason;
			
			// Note that ConnectTo() can take several seconds to return, both for success or failure,
			// depending upon hostname resolution and network response times, so it may be best to
			// do this in a separate thread to prevent the main GUI thread blocking.
			HRESULT hr = mSwitcherDiscovery->ConnectTo((CFStringRef)address, &mSwitcher, &failReason);
			if (SUCCEEDED(hr))
			{
				[self switcherConnected];
			}
			else
			{
				NSString* reason;
				switch (failReason)
				{
					case bmdSwitcherConnectToFailureNoResponse:
						reason = @"No response from Switcher";
						break;
					case bmdSwitcherConnectToFailureIncompatibleFirmware:
						reason = @"Switcher has incompatible firmware";
						break;
					case bmdSwitcherConnectToFailureCorruptData:
						reason = @"Corrupt data was received during connection attempt";
						break;
					case bmdSwitcherConnectToFailureStateSync:
						reason = @"State synchronisation failed during connection attempt";
						break;
					case bmdSwitcherConnectToFailureStateSyncTimedOut:
						reason = @"State synchronisation timed out during connection attempt";
						break;
					default:
						reason = @"Connection failed for unknown reason";
				}
				//Delay 2 seconds before everytime connect/reconnect
				//Because the session ID from ATEM switcher will alive not more then 2 seconds
				//After 2 second of idle, the session will be reset then reconnect won't cause error
				double delayInSeconds = 2.0;
				dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);
				dispatch_after(popTime, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0),
							   ^(void){
								   //To run in background thread
								   [self switcherDisconnected];
							   });
				[self logMessage:[NSString stringWithFormat:@"%@", reason]];
			}
		});
	});
}

- (void)switcherConnected
{
	HRESULT result;
	IBMDSwitcherMixEffectBlockIterator* iterator = NULL;
	IBMDSwitcherMediaPlayerIterator* mediaPlayerIterator = NULL;
	IBMDSwitcherSuperSourceBoxIterator* superSourceIterator = NULL;
	IBMDSwitcherInputIterator* inputIterator = NULL;
	IBMDSwitcherAudioInputIterator* audioInputIterator = NULL;
	isConnectedToATEM = YES;
	
	if ([[NSProcessInfo processInfo] respondsToSelector:@selector(beginActivityWithOptions:reason:)])
	{
		self.activity = [[NSProcessInfo processInfo] beginActivityWithOptions:0x00FFFFFF reason:@"receiving OSC messages"];
	}
	
	OSCMessage *newMsg = [OSCMessage createWithAddress:@"/atem/led/green"];
	[newMsg addFloat:1.0];
	[outPort sendThisMessage:newMsg];
	newMsg = [OSCMessage createWithAddress:@"/atem/led/red"];
	[newMsg addFloat:0.0];
	[outPort sendThisMessage:newMsg];
	
	NSString* productName;
	if (FAILED(mSwitcher->GetProductName((CFStringRef*)&productName)))
	{
		[self logMessage:@"Could not get switcher product name"];
		return;
	}
	
	[(SettingsWindow *)window showSwitcherConnected:productName];
	
	mSwitcher->AddCallback(mSwitcherMonitor);
	
	// Get the mix effect block iterator
	result = mSwitcher->CreateIterator(IID_IBMDSwitcherMixEffectBlockIterator, (void**)&iterator);
	if (FAILED(result))
	{
		[self logMessage:@"Could not create IBMDSwitcherMixEffectBlockIterator iterator"];
		return;
	}
	
	// Use the first Mix Effect Block
	if (S_OK != iterator->Next(&mMixEffectBlock))
	{
		[self logMessage:@"Could not get the first IBMDSwitcherMixEffectBlock"];
		return;
	}
	// Create an InputMonitor for each input so we can catch any changes to input names
	result = mSwitcher->CreateIterator(IID_IBMDSwitcherInputIterator, (void**)&inputIterator);
	if (SUCCEEDED(result))
	{
		IBMDSwitcherInput* input = NULL;
		
		// For every input, install a callback to monitor property changes on the input
		while (S_OK == inputIterator->Next(&input))
		{
			IBMDSwitcherInputAux* auxObj;
			result = input->QueryInterface(IID_IBMDSwitcherInputAux, (void**)&auxObj);
			if (SUCCEEDED(result))
			{
				BMDSwitcherInputId auxId;
				result = auxObj->GetInputSource(&auxId);
				if (SUCCEEDED(result))
				{
					mSwitcherInputAuxList.push_back(auxObj);
				}
			}
		}
		inputIterator->Release();
		inputIterator = NULL;
	}
	
	
	//Upstream Keyer
	IBMDSwitcherKeyIterator* keyIterator = NULL;
	result = mMixEffectBlock->CreateIterator(IID_IBMDSwitcherKeyIterator, (void**)&keyIterator);
	IBMDSwitcherKey* key = NULL;
	if (SUCCEEDED(result))
	{
		while (S_OK == keyIterator->Next(&key))
		{
			keyers.push_back(key);
			key->AddCallback(mUpstreamKeyerMonitor);
		}
		keyIterator->Release();
		keyIterator = NULL;
	}
	
	
	//Downstream Keyer
	IBMDSwitcherDownstreamKeyIterator* dskIterator = NULL;
	result = mSwitcher->CreateIterator(IID_IBMDSwitcherDownstreamKeyIterator, (void**)&dskIterator);
	IBMDSwitcherDownstreamKey* downstreamKey = NULL;
	if (SUCCEEDED(result))
	{
		while (S_OK == dskIterator->Next(&downstreamKey))
		{
			dsk.push_back(downstreamKey);
			downstreamKey->AddCallback(mDownstreamKeyerMonitor);
		}
	}
	dskIterator->Release();
	dskIterator = NULL;
	
	
	// Media Players
	result = mSwitcher->CreateIterator(IID_IBMDSwitcherMediaPlayerIterator, (void**)&mediaPlayerIterator);
	if (FAILED(result))
	{
		[self logMessage:@"Could not create IBMDSwitcherMediaPlayerIterator iterator"];
		return;
	}
	
	IBMDSwitcherMediaPlayer* mediaPlayer = NULL;
	while (S_OK == mediaPlayerIterator->Next(&mediaPlayer))
	{
		mMediaPlayers.push_back(mediaPlayer);
	}
	mediaPlayerIterator->Release();
	mediaPlayerIterator = NULL;
	
	// get media pool
	result = mSwitcher->QueryInterface(IID_IBMDSwitcherMediaPool, (void**)&mMediaPool);
	if (FAILED(result))
	{
		[self logMessage:@"Could not get IBMDSwitcherMediaPool interface"];
		return;
	}
	
	// get macro pool
	result = mSwitcher->QueryInterface(IID_IBMDSwitcherMacroPool, (void**)&mMacroPool);
	if (FAILED(result))
	{
		[self logMessage:@"Could not get IID_IBMDSwitcherMacroPool interface"];
		return;
	}
	mMacroPool->AddCallback(mMacroPoolMonitor);
	
	// get macro controller
	result = mSwitcher->QueryInterface(IID_IBMDSwitcherMacroControl, (void**)&mMacroControl);
	if (FAILED(result))
	{
		[self logMessage:@"Could not get IID_IBMDSwitcherMacroControl interface"];
		return;
	}
	
	// Super source
	if (mSuperSource) {
		result = mSuperSource->CreateIterator(IID_IBMDSwitcherSuperSourceBoxIterator, (void**)&superSourceIterator);
		if (FAILED(result))
		{
			[self logMessage:@"Could not create IBMDSwitcherSuperSourceBoxIterator iterator"];
			return;
		}
		IBMDSwitcherSuperSourceBox* superSourceBox = NULL;
		while (S_OK == superSourceIterator->Next(&superSourceBox))
		{
			mSuperSourceBoxes.push_back(superSourceBox);
		}
		superSourceIterator->Release();
		superSourceIterator = NULL;
	}
	
	// Audio Mixer (Output)
	mAudioMixer = NULL;
	result = mSwitcher->QueryInterface(IID_IBMDSwitcherAudioMixer, (void**)&mAudioMixer);
	if (FAILED(result))
	{
		[self logMessage:@"Could not get IBMDSwitcherAudioMixer interface"];
		return;
	}
	mAudioMixer->AddCallback(mAudioMixerMonitor);

	// Audio Inputs
	result = mAudioMixer->CreateIterator(IID_IBMDSwitcherAudioInputIterator, (void**)&audioInputIterator);
	if (FAILED(result))
	{
		[self logMessage:[NSString stringWithFormat:@"Could not create IBMDSwitcherAudioInputIterator iterator. code: %d", HRESULT_CODE(result)]];
		return;
	}

	IBMDSwitcherAudioInput* audioInput = NULL;
	while (S_OK == audioInputIterator->Next(&audioInput))
	{
		BMDSwitcherAudioInputId inputId;
		audioInput->GetAudioInputId(&inputId);
		mAudioInputs.insert(std::make_pair(inputId, audioInput));
		AudioInputMonitor *monitor = new AudioInputMonitor(self, inputId);
		audioInput->AddCallback(monitor);
		mMonitors.push_back(monitor);
		mAudioInputMonitors.insert(std::make_pair(inputId, monitor));
	}
	audioInputIterator->Release();
	audioInputIterator = NULL;
	
	switcherTransitionParameters = NULL;
	mMixEffectBlock->QueryInterface(IID_IBMDSwitcherTransitionParameters, (void**)&switcherTransitionParameters);
	switcherTransitionParameters->AddCallback(mTransitionParametersMonitor);
	
	mMixEffectBlock->AddCallback(mMixEffectBlockMonitor);
	
	self->mMixEffectBlockMonitor->updateSliderPosition();

	dispatch_async(dispatch_get_main_queue(), ^{
		[helpPanel setupWithDelegate: self];
	});
	
finish:
	if (iterator)
		iterator->Release();
}

- (void)switcherDisconnected
{
	
	isConnectedToATEM = NO;
	if (self.activity)
		[[NSProcessInfo processInfo] endActivity:self.activity];
	
	self.activity = nil;
	
	OSCMessage *newMsg = [OSCMessage createWithAddress:@"/atem/led/green"];
	[newMsg addFloat:0.0];
	[outPort sendThisMessage:newMsg];
	newMsg = [OSCMessage createWithAddress:@"/atem/led/red"];
	[newMsg addFloat:1.0];
	[outPort sendThisMessage:newMsg];
	
	[(SettingsWindow *)window showSwitcherDisconnected];
	
	[self cleanUpConnection];
	
	[self connectBMD];
}

- (void)cleanUpConnection
{
	while (mSwitcherInputAuxList.size())
	{
		mSwitcherInputAuxList.back()->Release();
		mSwitcherInputAuxList.pop_back();
	}
	
	while (mMediaPlayers.size())
	{
		mMediaPlayers.back()->Release();
		mMediaPlayers.pop_back();
	}
	
	if (mStills)
	{
		mStills->Release();
		mStills = NULL;
	}
	
	if (mMediaPool)
	{
		mMediaPool->Release();
		mMediaPool = NULL;
	}
	
	while (mSuperSourceBoxes.size())
	{
		mSuperSourceBoxes.back()->Release();
		mSuperSourceBoxes.pop_back();
	}
	
	while (keyers.size())
	{
		keyers.back()->Release();
		keyers.back()->RemoveCallback(mUpstreamKeyerMonitor);
		keyers.pop_back();
	}
	
	while (dsk.size())
	{
		dsk.back()->Release();
		dsk.back()->RemoveCallback(mDownstreamKeyerMonitor);
		dsk.pop_back();
	}
	
	if (mMixEffectBlock)
	{
		mMixEffectBlock->RemoveCallback(mMixEffectBlockMonitor);
		mMixEffectBlock->Release();
		mMixEffectBlock = NULL;
	}
	
	if (mSwitcher)
	{
		mSwitcher->RemoveCallback(mSwitcherMonitor);
		mSwitcher->Release();
		mSwitcher = NULL;
	}
	
	if (mMacroPool)
	{
		mMacroPool->RemoveCallback(mMacroPoolMonitor);
		mMacroPool->Release();
		mMacroPool = NULL;
	}
	
	for (auto const& it : mAudioInputs)
	{
		it.second->RemoveCallback(mAudioInputMonitors.at(it.first));
		it.second->Release();
	}
	
	if (mAudioMixer)
	{
		mAudioMixer->RemoveCallback(mAudioMixerMonitor);
		mAudioMixer->Release();
		mAudioMixer = NULL;
	}
	
	if (switcherTransitionParameters)
	{
		switcherTransitionParameters->RemoveCallback(mTransitionParametersMonitor);
	}
}

// We run this recursively so that we can get the
// delay from each command, and allow for variable
// wait times between sends
- (void)sendStatus
{
	[self sendEachStatus:0];
}

- (void)sendEachStatus:(int)nextMonitor
{
	if (nextMonitor < mMonitors.size()) {
		int delay = mMonitors[nextMonitor]->sendStatus();
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
			[self sendEachStatus:nextMonitor+1];
		});
	}
}

- (void)logMessage:(NSString *)message
{
	if (message) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self appendMessage:message];
		});
		NSLog(@"%@", message);
	}
}

- (void)appendMessage:(NSString *)message
{
	NSDate *now = [NSDate date];
	NSDateFormatter *formatter = nil;
	formatter = [[NSDateFormatter alloc] init];
	[formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
	
	NSString *messageWithNewLine = [NSString stringWithFormat:@"[%@] %@\n", [formatter stringFromDate:now], message];
	[formatter release];
	
	// Append string to textview
	[logTextView.textStorage appendAttributedString:[[NSAttributedString alloc]initWithString:messageWithNewLine]];
	
	[logTextView scrollRangeToVisible: NSMakeRange(logTextView.string.length, 0)];
	
	[logTextView setTextColor:[NSColor whiteColor]];
}

@end
