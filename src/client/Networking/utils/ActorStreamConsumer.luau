--!strict
local Types = require(script.Parent.Parent.types)

-- Framework-private override for isolated N4 adapter tests. Normal startup
-- constructs N5 directly; game code never installs a consumer. N4 queues no history.
local ActorStreamConsumer = {}
local installed: Types.ActorStreamConsumer? = nil
function ActorStreamConsumer.Install(consumer: Types.ActorStreamConsumer?): ()
	installed = consumer
end
function ActorStreamConsumer.Get(): Types.ActorStreamConsumer?
	return installed
end
return ActorStreamConsumer
