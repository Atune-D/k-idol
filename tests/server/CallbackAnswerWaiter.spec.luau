local UnitTestFramework = require("../Support/UnitTestFramework")
local CallbackAnswerWaiter = require("../../src/server/CallbackAnswerWaiter")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local function resumeWithCoroutineResume(waitingThread: thread, answer: any)
	local didResume, resumeError = coroutine.resume(waitingThread, answer)
	assert(didResume, resumeError)
end

describe("CallbackAnswerWaiter", function()
	it("returns at once when the answer arrives during the start call", function()
		local answer = CallbackAnswerWaiter.waitForCallbackAnswer(function(onAnswerReady)
			onAnswerReady({ isAccepted = true })
		end, resumeWithCoroutineResume)
		expect(answer).toEqual({ isAccepted = true })
	end)

	it("suspends only the waiting thread until a later callback, then returns that answer", function()
		local deliverAnswerLater = nil
		local returnedAnswer = nil
		local waitingThread = coroutine.create(function()
			returnedAnswer = CallbackAnswerWaiter.waitForCallbackAnswer(function(onAnswerReady)
				deliverAnswerLater = onAnswerReady
			end, resumeWithCoroutineResume)
		end)
		coroutine.resume(waitingThread)
		expect(coroutine.status(waitingThread)).toBe("suspended")
		expect(returnedAnswer).toBeNil()
		deliverAnswerLater({ isAccepted = true, isOwnedByPlayer = false })
		expect(coroutine.status(waitingThread)).toBe("dead")
		expect(returnedAnswer).toEqual({ isAccepted = true, isOwnedByPlayer = false })
	end)

	it("takes only the first answer; later calls of the callback are ignored", function()
		local resumeCount = 0
		local deliverAnswer = nil
		local returnedAnswer = nil
		local waitingThread = coroutine.create(function()
			returnedAnswer = CallbackAnswerWaiter.waitForCallbackAnswer(function(onAnswerReady)
				deliverAnswer = onAnswerReady
			end, function(threadToResume, answer)
				resumeCount += 1
				resumeWithCoroutineResume(threadToResume, answer)
			end)
		end)
		coroutine.resume(waitingThread)
		deliverAnswer("first")
		deliverAnswer("second")
		expect(returnedAnswer).toBe("first")
		expect(resumeCount).toBe(1)

		local immediateAnswer = CallbackAnswerWaiter.waitForCallbackAnswer(function(onAnswerReady)
			onAnswerReady("early")
			onAnswerReady("late")
		end, resumeWithCoroutineResume)
		expect(immediateAnswer).toBe("early")
	end)

	it("passes a raise of the start function to the caller without waiting", function()
		expect(function()
			CallbackAnswerWaiter.waitForCallbackAnswer(function()
				error("start failed on purpose")
			end, resumeWithCoroutineResume)
		end).toThrow("start failed on purpose")
	end)
end)
