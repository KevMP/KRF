import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

const sidebarsApi: SidebarsConfig = {
  apiSidebar: [
    {
      type: 'category',
      label: 'Server',
      items: ['Server/server'],
    },
    {
      type: 'category',
      label: 'Client',
      items: ['Client/client'],
    },
    {
      type: 'category',
      label: 'Actor',
      items: [
        'Actor/actor-runtime',
        'Actor/actor',
        'Actor/actor-registry',
        'Actor/actor-view-registry',
        'Actor/actor-view',
        'Actor/tags-view',
        'Actor/resources-view',
        'Actor/actions-view',
        'Actor/domain-view',
      ],
    },
    {
      type: 'category',
      label: 'Action',
      items: [
        'Action/action-registry',
        'Action/action-controller',
        'Action/action-types',
        'Action/action-execution-context',
      ],
    },
    {
      type: 'category',
      label: 'Property',
      items: ['Property/property-controller'],
    },
    {
      type: 'category',
      label: 'Resource',
      items: [
        'Resource/resource-registry',
        'Resource/resource-controller',
      ],
    },
    {
      type: 'category',
      label: 'Tags',
      items: [
        'Tags/tag-registry',
        'Tags/tag-controller',
      ],
    },
    {
      type: 'category',
      label: 'Controllers',
      items: ['Controllers/controller-registry'],
    },
    {
      type: 'category',
      label: 'Networking',
      items: [
        'Networking/schema',
        'Networking/replication-domain-registry',
      ],
    },
  ],
};

export default sidebarsApi;
