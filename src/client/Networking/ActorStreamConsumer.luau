--!strict
local Types = require(script.Parent.ActorStreamTypes)

-- N5 installs its private consumer before Client.Init. N4 never queues decoded history.
local ActorStreamConsumer = {}
local installed: Types.Consumer? = nil
function ActorStreamConsumer.Install(consumer: Types.Consumer?): ()
	installed = consumer
end
function ActorStreamConsumer.Get(): Types.Consumer?
	return installed
end
return ActorStreamConsumer
