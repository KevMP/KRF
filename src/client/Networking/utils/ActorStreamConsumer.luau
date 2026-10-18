--!strict
local Types = require(script.Parent.Parent.types)

-- Framework-private override for isolated Actor stream adapter tests. Normal startup
-- constructs the ActorView runtime directly; game code never installs a consumer. The stream runtime queues no history.
local ActorStreamConsumer = {}
local installed: Types.ActorStreamConsumer? = nil

function ActorStreamConsumer.Install(consumer: Types.ActorStreamConsumer?): ()
	installed = consumer
end

function ActorStreamConsumer.Get(): Types.ActorStreamConsumer?
	return installed
end

return ActorStreamConsumer
