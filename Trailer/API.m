
@interface API ()
{
	NSOperationQueue *requestQueue;
	NSDateFormatter *mediumFormatter;
    NSString *cacheDirectory;
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
	NSInteger networkIndicationCount;
#endif
}
@end

@implementation API

#ifdef __MAC_OS_X_VERSION_MIN_REQUIRED
	#define CACHE_MEMORY 1024*1024*4
	#define CACHE_DISK 1024*1024*128
#else
	#define CACHE_MEMORY 1024*1024*2
	#define CACHE_DISK 1024*1024*8
#endif

typedef void (^completionBlockType)(BOOL);

- (id)init
{
    self = [super init];
    if (self)
	{
		NSURLCache *cache = [[NSURLCache alloc] initWithMemoryCapacity:CACHE_MEMORY
														  diskCapacity:CACHE_DISK
															  diskPath:nil];
		[NSURLCache setSharedURLCache:cache];

		mediumFormatter = [[NSDateFormatter alloc] init];
		mediumFormatter.dateStyle = NSDateFormatterMediumStyle;
		mediumFormatter.timeStyle = NSDateFormatterMediumStyle;

		requestQueue = [[NSOperationQueue alloc] init];
		requestQueue.maxConcurrentOperationCount = 8;

		[self restartNotifier];

        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSURL *appSupportURL = [[fileManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] lastObject];
        appSupportURL = [appSupportURL URLByAppendingPathComponent:@"com.housetrip.Trailer"];
        cacheDirectory = appSupportURL.path;

        if([fileManager fileExistsAtPath:cacheDirectory])
            [self clearImageCache];
        else
            [fileManager createDirectoryAtPath:cacheDirectory withIntermediateDirectories:YES attributes:nil error:nil];
	}
    return self;
}

- (void)restartNotifier
{
	[self.reachability stopNotifier];
	self.reachability = [Reachability reachabilityWithHostName:[Settings shared].apiBackEnd];
	[self.reachability startNotifier];
}

- (void)error:(NSString*)errorString
{
	DLog(@"Failed to fetch %@",errorString);
}

- (void)updateLimitFromServer
{
	[self getRateLimitAndCallback:^(long long remaining, long long limit, long long reset) {
		self.requestsRemaining = remaining;
		self.requestsLimit = limit;
		if(reset>=0)
		{
			[[NSNotificationCenter defaultCenter] postNotificationName:RATE_UPDATE_NOTIFICATION
																object:nil
															  userInfo:nil];
		}
	}];
}

- (void)fetchStatusesForCurrentPullRequestsToMoc:(NSManagedObjectContext *)moc andCallback:(void (^)(BOOL))callback
{
	NSArray *prs = [DataItem allItemsOfType:@"PullRequest" inMoc:moc];

	if(!prs.count)
	{
		if(callback) callback(YES);
		return;
	}

	for(PullRequest *r in prs)
	{
		NSArray *statuses = [PRStatus statusesForPullRequestId:r.serverId inMoc:moc];
		for(PRStatus *s in statuses) s.postSyncAction = @(kPostSyncDelete);
	}

	NSInteger total = prs.count;
	__block NSInteger succeeded = 0;
	__block NSInteger failed = 0;

	for(PullRequest *p in prs)
	{
		[self getPagedDataInPath:p.statusesLink
				startingFromPage:1
						  params:nil
				 perPageCallback:^(id data, BOOL lastPage) {
					 for(NSDictionary *info in data)
					 {
						 PRStatus *s = [PRStatus statusWithInfo:info moc:moc];
						 if(!s.pullRequestId) s.pullRequestId = p.serverId;
					 }
				 } finalCallback:^(BOOL success, NSInteger resultCode) {
					 if(success) succeeded++; else failed++;
					 if(succeeded+failed==total)
					 {
						 if(failed==0)
						 {
							 [DataItem nukeDeletedItemsOfType:@"PRStatus" inMoc:moc];
							 if(callback) callback(YES);
						 }
						 else
						 {
							 if(callback) callback(NO);
						 }
					 }
				 }];
	}
}

- (void)fetchCommentsForCurrentPullRequestsToMoc:(NSManagedObjectContext *)moc andCallback:(void (^)(BOOL))callback
{
	NSArray *prs = [DataItem newOrUpdatedItemsOfType:@"PullRequest" inMoc:moc];
	for(PullRequest *r in prs)
	{
		NSArray *comments = [PRComment commentsForPullRequestUrl:r.url inMoc:moc];
		for(PRComment *c in comments) c.postSyncAction = @(kPostSyncDelete);
	}

	NSInteger totalOperations = 2;
	__block NSInteger succeded = 0;
	__block NSInteger failed = 0;

	completionBlockType completionCallback = ^(BOOL success){
		if(success) succeded++; else failed++;
		if(succeded+failed==totalOperations)
		{
			[DataItem nukeDeletedItemsOfType:@"PRComment" inMoc:moc];
			if(callback) callback(failed==0);
		}
	};

	[self _fetchCommentsForPullRequests:prs issues:YES toMoc:moc andCallback:completionCallback];

	[self _fetchCommentsForPullRequests:prs issues:NO toMoc:moc andCallback:completionCallback];
}

- (void)_fetchCommentsForPullRequests:(NSArray*)prs
							  issues:(BOOL)issues
							   toMoc:(NSManagedObjectContext *)moc
						 andCallback:(void(^)(BOOL success))callback
{
	NSInteger total = prs.count;
	if(!total)
	{
		if(callback) callback(YES);
		return;
	}

	__block NSInteger succeeded = 0;
	__block NSInteger failed = 0;

	for(PullRequest *p in prs)
	{
		NSString *link;
		if(issues)
			link = p.issueCommentLink;
		else
			link = p.reviewCommentLink;

		[self getPagedDataInPath:link
				startingFromPage:1
						  params:nil
				 perPageCallback:^(id data, BOOL lastPage) {
					 for(NSDictionary *info in data)
					 {
						 PRComment *c = [PRComment commentWithInfo:info moc:moc];
						 if(!c.pullRequestUrl) c.pullRequestUrl = p.url;

						 // check if we're assigned to a just created pull request, in which case we want to "fast forward" its latest comment dates to our own if we're newer
						 if(p.postSyncAction.integerValue == kPostSyncNoteNew)
						 {
							 NSDate *commentCreation = c.createdAt;
							 if(!p.latestReadCommentDate || [p.latestReadCommentDate compare:commentCreation]==NSOrderedAscending)
								 p.latestReadCommentDate = commentCreation;
						 }
					 }
				 } finalCallback:^(BOOL success, NSInteger resultCode) {
					 if(success) succeeded++; else failed++;
					 if(succeeded+failed==total)
					 {
						 callback(failed==0);
					 }
				 }];
	}
}

- (void)fetchRepositoriesAndCallback:(void(^)(BOOL success))callback
{
	[self syncUserDetailsAndCallback:^(BOOL success) {
		if(success)
		{
			NSManagedObjectContext *syncContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
			syncContext.parentContext = [AppDelegate shared].dataManager.managedObjectContext;
			syncContext.undoManager = nil;

			NSArray *items = [PullRequest itemsOfType:@"Repo" surviving:YES inMoc:syncContext];
			for(DataItem *i in items) i.postSyncAction = @(kPostSyncDelete);

			[self syncWatchedReposForUserToMoc:syncContext andCallback:^(BOOL success) {
				if(success)
				{
					[DataItem nukeDeletedItemsOfType:@"Repo" inMoc:syncContext];

					BOOL shouldHideByDefault = [Settings shared].hideNewRepositories;
					for(Repo *r in [DataItem newItemsOfType:@"Repo" inMoc:syncContext])
					{
						r.hidden = @(shouldHideByDefault);
						if(!shouldHideByDefault)
						{
							[[AppDelegate shared] postNotificationOfType:kNewRepoAnnouncement forItem:r];
						}
					}

					[AppDelegate shared].lastRepoCheck = [NSDate date];
					if(syncContext.hasChanges) [syncContext save:nil];
				}
				else
				{
					DLog(@"%@",[NSError errorWithDomain:@"YOUR_ERROR_DOMAIN"
												   code:101
											   userInfo:@{NSLocalizedDescriptionKey:@"Error while fetching data from GitHub"}]);
				}
				callback(success);
			}];
		}
		else if(callback) callback(NO);
	}];
}

- (void)detectAssignedPullRequestsInMoc:(NSManagedObjectContext *)moc andCallback:(void(^)(BOOL success))callback
{
	NSArray *prs = [DataItem newOrUpdatedItemsOfType:@"PullRequest" inMoc:moc];

	if(!prs.count)
	{
		if(callback) callback(YES);
		return;
	}

	for(PullRequest *r in prs)
	{
		NSArray *statuses = [PRStatus statusesForPullRequestId:r.serverId inMoc:moc];
		for(PRStatus *s in statuses) s.postSyncAction = @(kPostSyncDelete);
	}

	NSInteger totalOperations = prs.count;
	__block NSInteger succeeded = 0;
	__block NSInteger failed = 0;

	completionBlockType completionCallback = ^(BOOL success) {
		if(success) succeeded++; else failed++;
		if(succeeded+failed==totalOperations)
		{
			if(callback) callback(failed==0);
		}
	};

	for(PullRequest *p in prs)
	{
		if(p.issueUrl)
		{
			[self getDataInPath:p.issueUrl
						 params:nil
					andCallback:^(id data, BOOL lastPage, NSInteger resultCode) {
						if(data)
						{
							NSString *assignee = [[data ofk:@"assignee"] ofk:@"login"];
							BOOL assigned = [assignee isEqualToString:[Settings shared].localUser];
							p.assignedToMe = @(assigned);
							completionCallback(YES);
						}
						else
						{
							if(resultCode == 404 || resultCode == 410)
							{
								// 404/410 is fine, it means issue entry doesn't exist
								p.assignedToMe = @NO;
								completionCallback(YES);
							}
							else
							{
								completionCallback(NO);
							}
						}
					}];
		}
		else
		{
			completionCallback(YES);
		}
	}
}

- (void)checkPrClosuresInMoc:(NSManagedObjectContext *)moc andCallback:(void(^)(BOOL success))callback
{
	NSFetchRequest *f = [NSFetchRequest fetchRequestWithEntityName:@"PullRequest"];
	f.predicate = [NSPredicate predicateWithFormat:@"postSyncAction == %d and condition == %d",kPostSyncDelete, kPullRequestConditionOpen];
	f.returnsObjectsAsFaults = NO;
	NSArray *pullRequests = [moc executeFetchRequest:f error:nil];

	NSArray *prsToCheck = [pullRequests filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(PullRequest *r, NSDictionary *bindings) {
		Repo *parent = [Repo itemOfType:@"Repo" serverId:r.repoId moc:moc];
		return (!parent.hidden.boolValue) && (parent.postSyncAction.integerValue!=kPostSyncDelete);
	}]];

	NSInteger totalOperations = prsToCheck.count;
	if(totalOperations==0)
	{
		callback(YES);
		return;
	}

	__block NSInteger succeded = 0;
	__block NSInteger failed = 0;

	completionBlockType completionCallback = ^(BOOL success) {
		if(success) succeded++; else failed++;
		if(succeded+failed==totalOperations)
		{
			if(callback) callback(failed==0);
		}
	};

	for(PullRequest *r in prsToCheck)
		[self investigatePrClosureInMoc:r andCallback:completionCallback];
}

- (void)investigatePrClosureInMoc:(PullRequest *)r andCallback:(void(^)(BOOL success))callback
{
	DLog(@"Checking closed PR to see if it was merged: %@",r.title);

	Repo *parent = [Repo itemOfType:@"Repo" serverId:r.repoId moc:r.managedObjectContext];

	[self get:[NSString stringWithFormat:@"/repos/%@/pulls/%@",parent.fullName,r.number]
   parameters:nil
	  success:^(NSHTTPURLResponse *response, id data) {

		  NSDictionary *mergeInfo = [data ofk:@"merged_by"];
		  if(mergeInfo)
		  {
			  DLog(@"detected merged PR: %@",r.title);
			  NSString *mergeUserId = [[mergeInfo  ofk:@"id"] stringValue];
			  DLog(@"merged by user id: %@, our id is: %@",mergeUserId,[Settings shared].localUserId);
			  BOOL mergedByMyself = [mergeUserId isEqualToString:[Settings shared].localUserId];
			  if(!([Settings shared].dontKeepPrsMergedByMe && mergedByMyself))
			  {
				  DLog(@"detected merged PR: %@",r.title);
				  switch ([Settings shared].mergeHandlingPolicy)
				  {
					  case kPullRequestHandlingKeepMine:
					  {
						  if(r.sectionIndex.integerValue==kPullRequestSectionAll) break;
					  }
					  case kPullRequestHandlingKeepAll:
					  {
						  r.postSyncAction = @(kPostSyncDoNothing); // don't delete this
						  r.condition = @kPullRequestConditionMerged;
						  [[AppDelegate shared] postNotificationOfType:kPrMerged forItem:r];
					  }
					  case kPullRequestHandlingKeepNone: {}
				  }
			  }
			  else
			  {
				  DLog(@"will not announce merged PR: %@",r.title);
			  }
		  }
		  else
		  {
			  DLog(@"detected closed PR: %@",r.title);
			  switch([Settings shared].closeHandlingPolicy)
			  {
				  case kPullRequestHandlingKeepMine:
				  {
					  if(r.sectionIndex.integerValue==kPullRequestSectionAll) break;
				  }
				  case kPullRequestHandlingKeepAll:
				  {
					  r.postSyncAction = @(kPostSyncDoNothing); // don't delete this
					  r.condition = @kPullRequestConditionClosed;
					  [[AppDelegate shared] postNotificationOfType:kPrClosed forItem:r];
				  }
				  case kPullRequestHandlingKeepNone: {}
			  }
		  }
		  if(callback) callback(YES);

	  } failure:^(NSHTTPURLResponse *response, id data, NSError *error) {
		  r.postSyncAction = @(kPostSyncDoNothing); // don't delete this, we couldn't check, play it safe
		  if(callback) callback(NO);
	  }];
}

- (void)fetchPullRequestsForActiveReposAndCallback:(void(^)(BOOL success))callback
{
	[self syncUserDetailsAndCallback:^(BOOL success) {
		if(success)
		{
			[self autoSubscribeToReposAndCallback:^{
				NSManagedObjectContext *syncContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSConfinementConcurrencyType];
				syncContext.parentContext = [AppDelegate shared].dataManager.managedObjectContext;
				syncContext.undoManager = nil;
				[self syncToMoc:syncContext andCallback:callback];
			}];
		}
		else if(callback) callback(NO);
	}];
}

- (void)autoSubscribeToReposAndCallback:(void(^)())callback
{
	if([AppDelegate shared].lastRepoCheck &&
	   ([[NSDate date] timeIntervalSinceDate:[AppDelegate shared].lastRepoCheck] < [Settings shared].newRepoCheckPeriod*3600.0))
	{
		if(callback) callback();
		return;
	}

	[self fetchRepositoriesAndCallback:^(BOOL success) {
		if(callback) callback();
	}];
}

- (void)syncToMoc:(NSManagedObjectContext *)moc andCallback:(void(^)(BOOL success))callback
{
	NSArray *prs = [PullRequest itemsOfType:@"PullRequest" surviving:YES inMoc:moc];
	for(PullRequest *r in prs)
		if(r.condition.integerValue == kPullRequestConditionOpen)
			r.postSyncAction = @(kPostSyncDelete);

	NSArray *visibleRepos = [Repo visibleReposInMoc:moc];
	[self fetchPullRequestsForRepos:visibleRepos toMoc:moc andCallback:^(BOOL success) {
		if(success)
		{
			[self updatePullRequestsInMoc:moc andCallback:^(BOOL success) {
				if(success)
				{
					// do not cleanup PRs before because some "deleted" ones will turn to merged or closed ones
					[DataItem nukeDeletedItemsOfType:@"Repo" inMoc:moc];
					[DataItem nukeDeletedItemsOfType:@"PullRequest" inMoc:moc];

					NSArray *surviving = [PullRequest itemsOfType:@"PullRequest" surviving:YES inMoc:moc];
					for(PullRequest *r in surviving) [r postProcess];

					if(moc.hasChanges)
					{
						DLog(@"Database dirty after sync, saving");
						[moc save:nil];
					}

					if([Settings shared].showStatusItems)
					{
						self.successfulRefreshesSinceLastStatusCheck++;
					}
				}
				if(callback) callback(success);
			}];
		}
		else if(callback) callback(NO);
	}];
}

- (void)updatePullRequestsInMoc:(NSManagedObjectContext *)moc andCallback:(void(^)(BOOL success))callback
{
	BOOL willScanForStatuses = [self shouldScanForStatusesInMoc:moc];

	NSInteger totalOperations = 3;
	if(willScanForStatuses) totalOperations++;

	__block NSInteger succeded = 0, failed = 0;

	completionBlockType completionCallback = ^(BOOL success) {
		if(success) succeded++; else failed++;
		if(succeded+failed==totalOperations)
		{
			if(callback) callback(failed==0);
		}
	};

	if(willScanForStatuses)
		[self fetchStatusesForCurrentPullRequestsToMoc:moc andCallback:completionCallback];

	[self fetchCommentsForCurrentPullRequestsToMoc:moc andCallback:completionCallback];
	[self checkPrClosuresInMoc:moc andCallback:completionCallback];
	[self detectAssignedPullRequestsInMoc:moc andCallback:completionCallback];
}

- (BOOL)shouldScanForStatusesInMoc:(NSManagedObjectContext *)moc
{
	if(self.successfulRefreshesSinceLastStatusCheck % [Settings shared].statusItemRefreshInterval == 0)
	{
		if([Settings shared].showStatusItems)
		{
			self.successfulRefreshesSinceLastStatusCheck = 0;
			return YES;
		}
		[self clearAllStatusObjectsInMoc:moc];
	}
	return NO;
}

- (void)clearAllStatusObjectsInMoc:(NSManagedObjectContext *)moc
{
	for(PRStatus *s in [DataItem allItemsOfType:@"PRStatus" inMoc:moc])
	{
		[moc deleteObject:s];
	}
}

- (void)fetchPullRequestsForRepos:(NSArray *)repos toMoc:(NSManagedObjectContext *)moc andCallback:(void(^)(BOOL success))callback
{
	if(!repos.count)
	{
		if(callback) callback(YES);
		return;
	}
	NSInteger total = repos.count;
	__block NSInteger succeeded = 0;
	__block NSInteger failed = 0;
	for(Repo *r in repos)
	{
		[self getPagedDataInPath:[NSString stringWithFormat:@"/repos/%@/pulls",r.fullName]
				startingFromPage:1
						  params:nil
				 perPageCallback:^(id data, BOOL lastPage) {
					 for(NSDictionary *info in data)
					 {
						 [PullRequest pullRequestWithInfo:info moc:moc];
					 }
				 } finalCallback:^(BOOL success, NSInteger resultCode) {
					 if(success)
					 {
						 succeeded++;
					 }
					 else
					 {
						 if(resultCode == 404 || resultCode == 410) // 404/410 is an acceptable answer, it means the repo is gone
						 {
							 succeeded++;
							 r.postSyncAction = @(kPostSyncDelete);
						 }
						 else
						 {
							 failed++;
						 }
					 }
					 if(succeeded+failed==total)
					 {
						 callback(failed==0);
					 }
				 }];
	}
}

- (void)syncWatchedReposForUserToMoc:(NSManagedObjectContext *)moc andCallback:(void(^)(BOOL success))callback
{
	[self getPagedDataInPath:@"/user/subscriptions"
			startingFromPage:1
					  params:nil
			 perPageCallback:^(id data, BOOL lastPage) {
				 for(NSDictionary *info in data)
				 {
                     if([[info ofk:@"private"] boolValue])
                     {
                         NSDictionary *permissions = [info ofk:@"permissions"];
                         if([[permissions ofk:@"pull"] boolValue] ||
                            [[permissions ofk:@"push"] boolValue] ||
                            [[permissions ofk:@"admin"] boolValue])
                         {
                             [Repo repoWithInfo:info moc:moc];
                         }
                         else
                         {
                             DLog(@"Watched private repository '%@' seems to be inaccessible, skipping",[info ofk:@"full_name"]);
                             continue;
                         }
                     }
                     else
                     {
                         [Repo repoWithInfo:info moc:moc];
                     }
				 }
			 } finalCallback:^(BOOL success, NSInteger resultCode) {
				 if(callback) callback(success);
			 }];
}

- (void)syncUserDetailsAndCallback:(void (^)(BOOL))callback
{
	[self getDataInPath:@"/user"
				 params:nil
			andCallback:^(id data, BOOL lastPage, NSInteger resultCode) {
				if(data)
				{
					[Settings shared].localUser = [data ofk:@"login"];
					[Settings shared].localUserId = [data ofk:@"id"];
					[[NSUserDefaults standardUserDefaults] synchronize];
					if(callback) callback(YES);
				}
				else if(callback) callback(NO);
			}];
}

- (void)getPagedDataInPath:(NSString*)path
		 startingFromPage:(NSInteger)page
				   params:(NSDictionary*)params
		  perPageCallback:(void(^)(id data, BOOL lastPage))pageCallback
			finalCallback:(void(^)(BOOL success, NSInteger resultCode))finalCallback
{
	if(!path.length)
	{
		// handling empty or null fields as success, since we don't want syncs to fail, we simply have nothing to process
		dispatch_async(dispatch_get_main_queue(), ^{
			finalCallback(YES, -1);
		});
		return;
	}

	NSMutableDictionary *mparams;
	if(params) mparams = [params mutableCopy];
	else mparams = [NSMutableDictionary dictionaryWithCapacity:2];
	mparams[@"page"] = @(page);
	mparams[@"per_page"] = @100;
	[self getDataInPath:path
				 params:mparams
			andCallback:^(id data, BOOL lastPage, NSInteger resultCode) {
				if(data)
				{
					if(pageCallback)
					{
						pageCallback(data,lastPage);
					}

					if(lastPage)
					{
						finalCallback(YES, resultCode);
					}
					else
					{
						[self getPagedDataInPath:path
								startingFromPage:page+1
										  params:params
								 perPageCallback:pageCallback
								   finalCallback:finalCallback];
					}
				}
				else
				{
					finalCallback(NO, resultCode);
				}
			}];
}

- (void)getDataInPath:(NSString*)path params:(NSDictionary*)params andCallback:(void(^)(id data, BOOL lastPage, NSInteger resultCode))callback
{
	[self get:path
   parameters:params
	  success:^(NSHTTPURLResponse *response, id data) {
		  self.requestsRemaining = [[response allHeaderFields][@"X-RateLimit-Remaining"] floatValue];
		  self.requestsLimit = [[response allHeaderFields][@"X-RateLimit-Limit"] floatValue];
		  float epochSeconds = [[response allHeaderFields][@"X-RateLimit-Reset"] floatValue];
		  NSDate *date = [NSDate dateWithTimeIntervalSince1970:epochSeconds];
		  self.resetDate = [mediumFormatter stringFromDate:date];
		  [[NSNotificationCenter defaultCenter] postNotificationName:RATE_UPDATE_NOTIFICATION
															  object:nil
															userInfo:nil];
		  if(callback) callback(data, [API lastPage:response], response.statusCode);
	  } failure:^(NSHTTPURLResponse *response, id data, NSError *error) {
		  DLog(@"Failure for %@: %@",path,error);
		  if(callback) callback(nil, NO, response.statusCode);
	  }];
}

- (void)getRateLimitAndCallback:(void (^)(long long, long long, long long))callback
{
	[self get:@"/rate_limit"
	  parameters:nil
		 success:^(NSHTTPURLResponse *response, id data) {
			 long long requestsRemaining = [[response allHeaderFields][@"X-RateLimit-Remaining"] longLongValue];
			 long long requestLimit = [[response allHeaderFields][@"X-RateLimit-Limit"] longLongValue];
			 long long epochSeconds = [[response allHeaderFields][@"X-RateLimit-Reset"] longLongValue];
			 if(callback) callback(requestsRemaining,requestLimit,epochSeconds);
		 } failure:^(NSHTTPURLResponse *response, id data, NSError *error) {
			 if(callback)
			 {
				 if(response.statusCode==404 && data && ![[data ofk:@"message"] isEqualToString:@"Not Found"])
					 callback(10000,10000,0);
				 else
					 callback(-1, -1, -1);
			 }
		 }];
}

- (void)testApiAndCallback:(void (^)(NSError *))callback
{
	[self get:@"/rate_limit"
   parameters:nil
	  success:^(NSHTTPURLResponse *response, id data) {
		  if(callback) callback(nil);
	  } failure:^(NSHTTPURLResponse *response, id data, NSError *error) {
		  if(callback)
		  {
			  if(response.statusCode==404 && data && ![[data ofk:@"message"] isEqualToString:@"Not Found"])
				  callback(nil);
			  else
				  callback(error);
		  }
	  }];
}

+ (BOOL)lastPage:(NSHTTPURLResponse*)response
{
	NSString *linkHeader = [[response allHeaderFields] ofk:@"Link"];
	if(!linkHeader) return YES;
	return ([linkHeader rangeOfString:@"rel=\"next\""].location==NSNotFound);
}

- (NSOperation *)get:(NSString *)path
		 parameters:(NSDictionary *)params
			success:(void(^)(NSHTTPURLResponse *response, id data))successCallback
			failure:(void(^)(NSHTTPURLResponse *response, id data, NSError *error))failureCallback
{
	[self networkIndicationStart];

	NSString *authToken = [Settings shared].authToken;
	NSBlockOperation *o = [NSBlockOperation blockOperationWithBlock:^{

		NSString *expandedPath;
		if([path rangeOfString:@"/"].location==0)
		{
			NSString *apiPath = [Settings shared].apiPath;

			if([apiPath rangeOfString:@"/"].location==0)
				apiPath = [apiPath substringFromIndex:1];

			if(apiPath.length>1)
				if([[apiPath substringFromIndex:apiPath.length-2] isEqualToString:@"/"])
					apiPath = [apiPath substringToIndex:apiPath.length-2];

			expandedPath = [[[@"https://" stringByAppendingString:[Settings shared].apiBackEnd]
							 stringByAppendingPathComponent:apiPath]
							stringByAppendingString:path];
		}
		else
		{
			expandedPath = path;
		}

		if(params.count)
		{
			expandedPath = [expandedPath stringByAppendingString:@"?"];
			NSMutableArray *pairs = [NSMutableArray arrayWithCapacity:params.count];
			for(NSString *key in params)
			{
				[pairs addObject:[NSString stringWithFormat:@"%@=%@", key, params[key]]];
			}
			expandedPath = [expandedPath stringByAppendingString:[pairs componentsJoinedByString:@"&"]];
		}

		NSMutableURLRequest *r = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:expandedPath]
															  cachePolicy:NSURLRequestUseProtocolCachePolicy
														  timeoutInterval:NETWORK_TIMEOUT];
		[r setValue:@"Trailer" forHTTPHeaderField:@"User-Agent"];
		[r setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
		if(authToken) [r setValue:[@"token " stringByAppendingString:authToken] forHTTPHeaderField:@"Authorization"];

		NSError *error;
		NSHTTPURLResponse *response;
		NSData *data = [NSURLConnection sendSynchronousRequest:r returningResponse:&response error:&error];
		id parsedData = nil;
		if(data.length) parsedData = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];

		if(!error && response.statusCode>299)
		{
			error = [NSError errorWithDomain:@"Error response received" code:response.statusCode userInfo:nil];
		}
		if(error)
		{
			DLog(@"GET %@ - FAILED: %@",expandedPath,error);
			if(failureCallback)
			{
				dispatch_async(dispatch_get_main_queue(), ^{
					failureCallback(response, parsedData, error);
				});
			}
		}
		else
		{
			DLog(@"GET %@ - RESULT: %ld",expandedPath,(long)response.statusCode);
			if(successCallback)
			{
				dispatch_async(dispatch_get_main_queue(), ^{
					successCallback(response, parsedData);
				});
			}
		}

		[self networkIndicationEnd];
	}];
	o.queuePriority = NSOperationQueuePriorityVeryHigh;
	[requestQueue addOperation:o];
	return o;
}

// warning: now calls back on thread!!
- (NSOperation *)getImage:(NSString *)path
				  success:(void(^)(NSHTTPURLResponse *response, NSData *imageData))successCallback
				  failure:(void(^)(NSHTTPURLResponse *response, NSError *error))failureCallback
{
	double delayInSeconds = 0.5;
	dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
	dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
		[self networkIndicationStart];
	});

	NSBlockOperation *o = [NSBlockOperation blockOperationWithBlock:^{

		NSMutableURLRequest *r = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:path]
															  cachePolicy:NSURLRequestReturnCacheDataElseLoad
														  timeoutInterval:NETWORK_TIMEOUT];
		[r setValue:@"Trailer" forHTTPHeaderField:@"User-Agent"];

		NSError *error;
		NSHTTPURLResponse *response;
		NSData *data = [NSURLConnection sendSynchronousRequest:r returningResponse:&response error:&error];
		if(!error && response.statusCode>299)
		{
			error = [NSError errorWithDomain:@"Error response received" code:response.statusCode userInfo:nil];
		}
		if(error)
		{
			DLog(@"GET IMAGE %@ - FAILED: %@",path,error);
			if(failureCallback)
			{
                failureCallback(response, error);
			}
		}
		else
		{
			DLog(@"GET IMAGE %@ - RESULT: %ld",path,(long)response.statusCode);
			if(successCallback)
			{
				if(data.length)
				{
                    successCallback(response, data);
				}
				else
				{
                    failureCallback(response, error);
				}
			}
		}

		[self networkIndicationEnd];
	}];
	o.queuePriority = NSOperationQueuePriorityVeryLow;
	[requestQueue addOperation:o];
	return o;
}

- (void)networkIndicationStart
{
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
	dispatch_async(dispatch_get_main_queue(), ^{
		if(++networkIndicationCount==1)
			[UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
	});
#endif
}

- (void)networkIndicationEnd
{
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
	dispatch_async(dispatch_get_main_queue(), ^{
		if(--networkIndicationCount==0)
			[UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
	});
#endif
}

- (void)clearImageCache
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray *files = [fileManager contentsOfDirectoryAtPath:cacheDirectory error:nil];
    for(NSString *f in files)
    {
        if([f rangeOfString:@"imgcache-"].location==0)
        {
            NSString *path = [cacheDirectory stringByAppendingPathComponent:f];
            [fileManager removeItemAtPath:path error:nil];
        }
    }
}

- (void)expireOldImageCacheEntries
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray *files = [fileManager contentsOfDirectoryAtPath:cacheDirectory error:nil];
    for(NSString *f in files)
    {
        NSDate *now = [NSDate date];
        if([f rangeOfString:@"imgcache-"].location==0)
        {
            NSString *path = [cacheDirectory stringByAppendingPathComponent:f];
            NSError *error;
            NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:&error];
            NSDate *date = attributes[NSFileCreationDate];
            if([now timeIntervalSinceDate:date]>(3600.0*24))
                [fileManager removeItemAtPath:path error:nil];
        }
    }
}

- (BOOL)haveCachedImage:(NSString *)path
                forSize:(CGSize)imageSize
     tryLoadAndCallback:(void (^)(IMAGE_CLASS *image))callbackOrNil
{
    // mix image path, size, and app version into one md5
	NSString *currentAppVersion = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    NSString *imageKey = [[NSString stringWithFormat:@"%@ %f %f %@",
                           path,
                           imageSize.width,
                           imageSize.height,
                           currentAppVersion] md5hash];

#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
    NSString *imagePath = [cacheDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"imgcache-%@-%ld", imageKey, (long)GLOBAL_SCREEN_SCALE]];
#else
    NSString *imagePath = [cacheDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"imgcache-%@", imageKey]];
#endif

    NSFileManager *fileManager = [NSFileManager defaultManager];
    if([fileManager fileExistsAtPath:imagePath])
    {
		IMAGE_CLASS *ret;
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
		CFDataRef imgData = (__bridge CFDataRef)[NSData dataWithContentsOfFile:imagePath];
		CGDataProviderRef imgDataProvider = CGDataProviderCreateWithCFData (imgData);
		CGImageRef cfImage = CGImageCreateWithPNGDataProvider(imgDataProvider, NULL, false, kCGRenderingIntentDefault);
		CGDataProviderRelease(imgDataProvider);

		ret = [[UIImage alloc] initWithCGImage:cfImage
										 scale:GLOBAL_SCREEN_SCALE
								   orientation:UIImageOrientationUp];
		CGImageRelease(cfImage);
#else
        ret = [[NSImage alloc] initWithContentsOfFile:imagePath];
#endif
        if(ret)
        {
            if(callbackOrNil) callbackOrNil(ret);
            return YES;
        }
        else
        {
            [fileManager removeItemAtPath:imagePath error:nil];
        }
    }

    if(callbackOrNil)
    {
        [self getImage:path
               success:^(NSHTTPURLResponse *response, NSData *imageData) {
                   id image = nil;
                   if(imageData)
                   {
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
                       image = [[UIImage imageWithData:imageData] scaleToFillSize:imageSize];
                       [UIImagePNGRepresentation(image) writeToFile:imagePath atomically:YES];
#else
                       image = [[[NSImage alloc] initWithData:imageData] scaleToFillSize:imageSize];
                       [[image TIFFRepresentation] writeToFile:imagePath atomically:YES];
#endif
                   }
                   dispatch_async(dispatch_get_main_queue(), ^{
                       callbackOrNil(image);
                   });
               } failure:^(NSHTTPURLResponse *response, NSError *error) {
                   dispatch_async(dispatch_get_main_queue(), ^{
                       callbackOrNil(nil);
                   });
               }];
    }

    return NO;
}

- (NSString *)lastUpdateDescription
{
	if([AppDelegate shared].isRefreshing)
	{
		return @"Refreshing...";
	}
	else if([AppDelegate shared].lastUpdateFailed)
	{
		return @"Last update failed";
	}
	else
	{
		NSDate *lastSuccess = [AppDelegate shared].lastSuccessfulRefresh;
		if(!lastSuccess) lastSuccess = [NSDate date];
		long ago = (long)[[NSDate date] timeIntervalSinceDate:lastSuccess];
		if(ago<10)
			return @"Just updated";
		else
			return [NSString stringWithFormat:@"Updated %ld seconds ago",(long)ago];
	}

}

@end
