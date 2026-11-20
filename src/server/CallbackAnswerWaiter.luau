-- CallbackAnswerWaiter: lets the thread that must RETURN an answer (a RemoteFunction's
-- OnServerInvoke handler) wait for an answer that arrives through a callback (for example
-- MarketplaceStylingItemResolver:startAnsweringStylingItemOwnershipRequest, spec §2.14), without
-- blocking anything else: only the waiting thread is suspended, every other thread keeps running.
--
-- Pure logic on Luau coroutines; how a suspended thread is resumed is injected, because Roblox
-- threads must be resumed through the task library (ServerMain passes task.spawn) while Lune tests
-- pass coroutine.resume.
--
-- PUBLIC API
--   CallbackAnswerWaiter.waitForCallbackAnswer(startAnswering, resumeWaitingThreadWithAnswer) -> answer
--     startAnswering(onAnswerReady)   starts the work; onAnswerReady(answer) may be called during
--         startAnswering (then nothing waits) or later from any thread. Only the FIRST call counts;
--         later calls are ignored.
--     resumeWaitingThreadWithAnswer(waitingThread, answer)   resumes the suspended caller.
--   Must be called from a thread that may yield. If startAnswering raises, the error reaches the
--   caller and nothing waits. The caller is responsible for the callback being called at all
--   (the resolver guarantees it within its own timeout).

local CallbackAnswerWaiter = {}

function CallbackAnswerWaiter.waitForCallbackAnswer(
	startAnswering: (onAnswerReady: (any) -> ()) -> (),
	resumeWaitingThreadWithAnswer: (thread, any) -> ()
): any
	local hasAnswer = false
	local receivedAnswer = nil
	local waitingThread: thread? = nil
	startAnswering(function(answer)
		if hasAnswer then
			return
		end
		hasAnswer = true
		receivedAnswer = answer
		if waitingThread ~= nil then
			local threadToResume = waitingThread
			waitingThread = nil
			resumeWaitingThreadWithAnswer(threadToResume, answer)
		end
	end)
	if hasAnswer then
		return receivedAnswer
	end
	waitingThread = coroutine.running()
	return coroutine.yield()
end

return table.freeze(CallbackAnswerWaiter)
