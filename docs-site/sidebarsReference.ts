import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

const sidebars: SidebarsConfig = {
  referenceSidebar: [
    'index',
    {
      type: 'category',
      label: 'Getting started',
      collapsed: false,
      items: [
        'getting-started/initialization',
        'getting-started/initialization-api',
        'getting-started/events',
        'getting-started/project-tools',
        'getting-started/world',
        'getting-started/cloud-deployment',
      ],
    },
    {
      type: 'category',
      label: 'Actors',
      items: [
        {type: 'doc', id: 'actors/guide', label: 'Guide'},
        {type: 'doc', id: 'actors/api', label: 'Server API'},
        {type: 'doc', id: 'actors/client-views', label: 'Client views'},
        {type: 'doc', id: 'actors/client-views-api', label: 'Client views API'},
      ],
    },
    {
      type: 'category',
      label: 'Controllers',
      items: [
        {type: 'doc', id: 'controllers/guide', label: 'Guide'},
        {type: 'doc', id: 'controllers/api', label: 'API'},
      ],
    },
    {
      type: 'category',
      label: 'Properties',
      items: [
        {type: 'doc', id: 'properties/guide', label: 'Guide'},
        {type: 'doc', id: 'properties/api', label: 'API'},
      ],
    },
    {
      type: 'category',
      label: 'Tags',
      items: [
        {type: 'doc', id: 'tags/guide', label: 'Guide'},
        {type: 'doc', id: 'tags/api', label: 'API'},
      ],
    },
    {
      type: 'category',
      label: 'Resources',
      items: [
        {type: 'doc', id: 'resources/guide', label: 'Guide'},
        {type: 'doc', id: 'resources/api', label: 'API'},
      ],
    },
    {
      type: 'category',
      label: 'Actions',
      items: [
        {type: 'doc', id: 'actions/guide', label: 'Server lifecycle'},
        {type: 'doc', id: 'actions/api', label: 'Server API'},
        'actions/requests',
        'actions/routes',
        {type: 'doc', id: 'actions/client-api', label: 'Client API'},
      ],
    },
    {
      type: 'category',
      label: 'Input',
      items: [
        'input/guide',
        'input/api',
        'input/recognition',
        'input/recognition-api',
      ],
    },
    {
      type: 'category',
      label: 'ClientControls',
      items: ['controls/guide', 'controls/api'],
    },
    {
      type: 'category',
      label: 'Presentation',
      items: ['presentation/guide', 'presentation/api'],
    },
    {
      type: 'category',
      label: 'Networking',
      items: [
        {
          type: 'category',
          label: 'Schemas',
          items: ['schemas/guide', 'schemas/api'],
        },
        {
          type: 'category',
          label: 'Replication domains',
          items: ['replication/guide', 'replication/api'],
        },
        {
          type: 'category',
          label: 'Commands',
          items: ['commands/guide', 'commands/api'],
        },
        {
          type: 'category',
          label: 'Hints',
          items: ['hints/guide', 'hints/api'],
        },
      ],
    },
  ],
};

export default sidebars;
